// :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
// Kubernetes resources for the tekton based CI/CD paradigm GATES (g8s)
// ---------------------------------------------------------------------------
//
//
// !!!! =========================> EXPERIMENTAL <======================== !!!!
// 
//
// ---------------------------------------------------------------------------
// Docs, code, and releases: https://github.com/muxmuse/k8s.libsonnet
//
// author: mfa@ddunicorn.com
// version: jsonnet -e '(import "./k8s.libsonnet").version'
// --------------------------------------------------------------------------
// MIT License
// 
// Copyright (c) 2021 Maximilian Felix Appel
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
// :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

local k8s = import './k8s.libsonnet';

/*
From https://kubernetes.io/docs/concepts/configuration/overview/

> imagePullPolicy: Always: every time the kubelet launches a container, the
> kubelet queries the container image registry to resolve the name to an
> image digest. If the kubelet has a container image with that exact digest
> cached locally, the kubelet uses its cached image; otherwise, the kubelet
> downloads (pulls) the image with the resolved digest, and uses that image
> to launch the container

So it should not hurt to set it to always, as long as the registry is
reliably available. 
*/

local elServiceName(service) = 'el-' + k8s.nameFrom(service);

local prefix(name) = 'g8s-' + name;

local gitInput(name, url, revision) = {
  name: name,
  resourceSpec: {
    type: 'git',
    params: [{
      name: 'revision',
      value: revision
    }, {
      name: 'url',
      value: url
    }]
  }
};

local github = {
  interceptors:: function(branch, apiKeySecretName, apiKeySecretKey = 'SECRET', eventTypes = ['push']) [{
    # Validate github webhook and secure EventListener with a custom
    # API key (needs to be configured in github, too.)
    github: {
      secretRef: {
        secretName: apiKeySecretName,
        secretKey: apiKeySecretKey
      },
      eventTypes: eventTypes
    }
  },{
    cel: {
      # Restrict to branch
      # https://tekton.dev/docs/triggers/eventlisteners/#cel-interceptors
      filter: "body.ref == 'refs/heads/%s'" % [branch],
    }
  }],

  bindings:: [{
    name: 'gitrevision',
    value: '$(body.after)'
  }]
};

local azurecr = {
  interceptors:: function(repo, tag) [{
    cel: {
      # Restrict to specific repository
      # https://tekton.dev/docs/triggers/eventlisteners/#cel-interceptors
      filter: "body.action == 'push' && (body.request.host + '/' + body.target.repository) == '%s' && body.target.tag == '%s'" % [repo, tag],
    },
  }]
};

// Creates
// - a ServiceAccount with assigned private ssh key (git clone)
// - an api key for the ServiceAccount
// - a role containing given rules
// - a rolebinding
local saTask = function(namespace, name, clusterRoleDeployName, sshPrivateKeySecretName, rules) {
  
  saTask: k8s.v1.r('ServiceAccount', namespace,  name) + {
    secrets: [ { name: sshPrivateKeySecretName } ],
    // imagePullSecrets: [ { name: regcredSecretName } ]
  },

  deploymentRole: k8s.r('rbac.authorization.k8s.io/v1', 'Role', 
    namespace, prefix(name)) + {
    # list of verbs:
    # https://kubernetes.io/docs/reference/access-authn-authz/authorization/#determine-the-request-verb
    rules+: rules,
  },

  rbCiCd: k8s.r('rbac.authorization.k8s.io/v1', 'RoleBinding', 
    namespace, prefix(name)) + {
    roleRef: {
      apiGroup: 'rbac.authorization.k8s.io',
      kind: 'Role',
      name: k8s.nameFrom($.deploymentRole)
    },
    subjects: [{
      kind: 'ServiceAccount',
      name: k8s.nameFrom($.saTask)
    }]
  },

  kubeApiSecretForSaDeploy: k8s.v1.r('Secret', namespace, prefix(name)) + {
    metadata+: {
      annotations: {
        'kubernetes.io/service-account.name': '%s:%s' % [
          k8s.nameFrom(namespace), 
          k8s.nameFrom($.saTask)
        ]
      }
    },
    type: 'kubernetes.io/service-account-token'
  },

  crbDeployComponentstatuses: k8s.r('rbac.authorization.k8s.io/v1', 'ClusterRoleBinding', 
    namespace, prefix(k8s.nameFrom(namespace) + '-' + name)) + {
    subjects: [{
      kind: 'ServiceAccount',
      name: k8s.nameFrom($.saTask),
      namespace: k8s.nameFrom(namespace),
      apiGroup: ''
    }], 
    roleRef: {
      kind: 'ClusterRole',
      name: clusterRoleDeployName,
      apiGroup: 'rbac.authorization.k8s.io'
    }
  },
};

local saEventListener = function(namespace, name, clusterRoleName, readSecretNames=[]) {
  # ServiceAccount for EventListener
  saEl: k8s.v1.r('ServiceAccount', namespace, prefix(name)),
  
  roleEventListener: k8s.r('rbac.authorization.k8s.io/v1', 'Role', 
    namespace, prefix(name)) + {
    rules+: [
     # Permissions for every EventListener deployment to function
    {
      apiGroups: ["triggers.tekton.dev"],
      resources: [
        "eventlisteners",
        "triggerbindings",
        "triggertemplates",
        "triggers"
      ],
      verbs: ["get", "list", "watch"]
    },
    {
      apiGroups: [""],
      # secrets are only needed for Github/Gitlab interceptors,
      resources: ["secrets"],
      verbs: ["get", "list", "watch"],
      resourceNames: readSecretNames
    },
    # Permissions to create resources in associated TriggerTemplates
    {
      apiGroups: ["tekton.dev"],
      resources: ["pipelineruns", "pipelineresources", "taskruns"],
      verbs: ["create", "watch"]
    },
    {
      apiGroups: [""],
      resources: ["serviceaccounts"],
      verbs: ["impersonate"]
    },
    {
      apiGroups: [""],
      resources: ["configmaps"],
      verbs: ["list", "get", "watch"]
    }]
  },

  rbEventListener: k8s.r('rbac.authorization.k8s.io/v1', 'RoleBinding', 
    namespace, prefix(name)) + {
    subjects: [{
      kind: 'ServiceAccount',
      name: k8s.nameFrom($.saEl),
      apiGroup: ''
    }], 
    roleRef: {
      kind: 'Role',
      name: k8s.nameFrom($.roleEventListener),
      apiGroup: 'rbac.authorization.k8s.io'
    }
  },

  crbEventListener: k8s.r('rbac.authorization.k8s.io/v1', 'ClusterRoleBinding', 
    namespace, prefix(k8s.nameFrom(namespace) + '-' + name)) + {
    subjects: [{
      kind: 'ServiceAccount',
      name: k8s.nameFrom($.saEl),
      namespace: k8s.nameFrom(namespace),
      apiGroup: ''
    }], 
    roleRef: {
      kind: 'ClusterRole',
      name: clusterRoleName,
      apiGroup: 'rbac.authorization.k8s.io'
    }
  },
};

local tasks = {
  build:: function (name, repoUrl, branch, imageRepo, regcredSecretName, serviceAccountName, kanikoCachePvcName = null, kanikoArgs = ['--cache=true']) { spec: { 
    # Template parameters definitions. Available in the whole template
    # with $(tt.params)
    params: [],
    # Templates for {TaskRun, PiplineRun}s to create when triggered
    resourcetemplates: [{ 
      apiVersion: 'tekton.dev/v1beta1',
      kind: 'TaskRun',
      metadata: { generateName: prefix(name) },
      spec: {
        serviceAccountName: serviceAccountName, // k8s.nameFrom($.saCiCd),
        resources: { inputs: [ gitInput('source', repoUrl, branch) ] }, // '$(tt.params.gitrevision)'
        podTemplate: {
          volumes: [{
            name: 'dockerconfigjson',
            secret: { secretName: regcredSecretName }
          }]
          +
          if kanikoCachePvcName != null then [{ 
            name: 'image-cache', persistentVolumeClaim: { claimName: kanikoCachePvcName }
          }] else []
        },
        taskSpec: {
          resources: { inputs: [{ name: 'source', type: 'git' }] },
          steps: [{
            image: 'gcr.io/kaniko-project/executor',
            args: [
              '--context=$(inputs.resources.source.path)',
              '--destination=%s:%s' % [imageRepo, branch],
              // '--use-new-run'
            ] + kanikoArgs,
            volumeMounts: [{ 
              name: 'dockerconfigjson', 
              mountPath: '/kaniko/.docker/config.json', 
              subPath: '.dockerconfigjson'
            }]
            + 
            if kanikoCachePvcName != null then [{
              name: 'image-cache',
              mountPath: '/cache'
            }] else [],
            resources: { requests: { memory: '4Gi' }, limits: { memory: '4Gi' } }
          }]
        }
      }
    }]
  } },

  deploy:: function(namespace, name, repoUrl, branch, serviceAccountName) { spec: { 
    # Template parameters definitions. Available in the whole Template
    # with $(tt.params) and bound with event listener bindings
    params: [{ name: 'imageVersion', default: ':%s' % [branch] }],
    # Templates for {TaskRun, PiplineRun}s to create when triggered
    resourcetemplates: [{ 
      apiVersion: 'tekton.dev/v1beta1',
      kind: 'TaskRun',
      metadata: { generateName: prefix(name) },
      spec: {
        serviceAccountName: serviceAccountName, // k8s.nameFrom($.saCiCd),
        resources: { inputs: [gitInput('config', repoUrl, branch)] },
        taskSpec: {
          resources: { inputs: [{ name: 'config', type: 'git' }] },
          steps: [{
            # Deploy without revision information
            image: 'muxmuse/kubecfg',
            command: ['kubecfg', 'update'],
            args: [
              // tag created objects for garbage collection on future deployments
              '--gc-tag', k8s.nameFrom(namespace),
              // restrict actions to the selected namespace
              '--namespace', k8s.nameFrom(namespace),
              '--tla-str', 'imageVersion=$(tt.params.imageVersion)',
              '$(inputs.resources.config.path)/' + k8s.nameFrom(namespace) + '/index.k8s.jsonnet'
            ]
          }]
        }
      }
    }]
  } },

  updateBaseImage:: function (name, repoUrl, branch, imageRepo, serviceAccountName) { spec: {
    local escapedImageRepo = std.strReplace(std.strReplace(imageRepo, '/', '\\/'), '.', '\\.'),
    local gitImage = 'alpine/git',
    # Template parameters definitions. Available in the whole template
    # with $(tt.params)
    params: [{ name: 'imageVersion', default: ':%s' + branch }],
    # Templates for {TaskRun, PiplineRun}s to create when triggered
    resourcetemplates: [{ 
      apiVersion: 'tekton.dev/v1beta1',
      kind: 'TaskRun',
      metadata: { generateName: prefix(name) },
      spec: {
        serviceAccountName: serviceAccountName, // k8s.nameFrom($.saCiCd),
        resources: { inputs: [ gitInput('source', repoUrl, branch) ] }, // '$(tt.params.gitrevision)'
        workspaces: [{
          name: 'repo',
          emptyDir: {}
        }],
        taskSpec: {
          resources: { inputs: [{ name: 'source', type: 'git' }] },
          workspaces: [{
            name: 'repo'
          }],
          steps: [{
            image: gitImage,
            script: |||
              #!/usr/bin/env ash
              ln -s ~/.ssh /root/.ssh
              cd $(workspaces.repo.path)
              git config --global user.email "office@ddunicorn.com"
              git config --global user.name "g8s bot"
              git clone %s --branch %s $(workspaces.repo.path)
              sed -r "s/(FROM[[:space:]]+%s)(:[[:alnum:]]+)/\\1$(tt.params.imageVersion)/gi" -i Dockerfile
              git add Dockerfile
              git commit -m '+ update base image'
              git push
            ||| % [repoUrl, branch, escapedImageRepo],
          }]
        }
      }
    }]
  } },
};

local eventListener = function(namespace, name, template, serviceAccountName, interceptors = [], bindings = [])
  k8s.r('triggers.tekton.dev/v1alpha1', 'EventListener', namespace, prefix(name)) + {
  spec+: {
    serviceAccountName: serviceAccountName, // k8s.nameFrom($.saEventListener),
    triggers: [{
      name: name,
      interceptors: interceptors,
      bindings: bindings,
      template: template
    }]
  }
};

local ingress = function(namespace, name, el, hostname, issuerName, path = '/' + name) 
  k8s.network.v1beta1.ingress(namespace, prefix(name), hostname, issuerName) + {
  spec+: {
    rules+: [{
      host: hostname,
      http+: {
        paths+: [{
          path: path,
          backend: {
            serviceName: elServiceName(el),
            servicePort: 8080,
          }
        }]
      }
    }]
  }
};

// https://crontab.guru
local cronjob = function(namespace, name, el, schedule = '0 18 */1 * *', port = 8080) k8s.r('batch/v1beta1', 'CronJob', namespace, name) + {
    spec+: { 
      schedule: schedule,
      jobTemplate: { spec: { template: { spec: {
        containers: [{
          name: 'wget',
          image: 'busybox',
          args: ['wget', '--spider', '%s.%s.svc.cluster.local:%d' % [elServiceName(el), k8s.nameFrom(namespace), port] ]
        }],
        restartPolicy: 'Never'
    } } } } }
};

{
  github:: github,
  azurecr:: azurecr,

  saTask:: saTask,
  saEventListener:: saEventListener,

  tasks:: tasks,
  eventListener:: eventListener,

  ingress:: ingress,
  cronjob:: cronjob,

  elServiceName:: elServiceName,
  prefix:: prefix,
}