// ===========================================================================
// MAIN
// ---------------------------------------------------------------------------

local _r(apiVersion, kind, namespace, name) = {
  apiVersion: apiVersion,
  kind: kind,
  metadata: {
    name: name,
    [if namespace != null then 'namespace'] : namespace.metadata.name
  }
};

local namespaceFrom(obj) = {
  metadata: {
    name: obj.metadata.namespace
  }
};

local nameFrom(obj) = obj.metadata.name;

local volumeFromSealedSecret(name, sealedSecret) = {
  name: name,
  secret: {
    secretName: sealedSecret.spec.template.metadata.name,
  }
};

local environmentVariablesFromSealedSecret(sealedSecret, names = null) = [
  {
    name: key,
    valueFrom: { 
      secretKeyRef: { 
        name: sealedSecret.spec.template.metadata.name,
        key: key,
      },
    },
  } for key in (if names != null then names else std.objectFields(sealedSecret.spec.encryptedData))
];

local environmentVariablesFromConfigMap(configMap, names = null) = [
  {
    name: name,
    valueFrom: {
      configMapKeyRef: {
        name: configMap.metadata.name,
        key: name,
      }
    }
  } for name in (if names != null then names else std.objectFields(configMap.data))
];

local nameValuePairsFromDotEnv(dotEnv, valueMap = function(e) e) = std.filterMap(
  function (e) !std.startsWith(e, '#') && std.length(std.split(e, '=')) >= 2, 
  function(e) { 
    name: std.split(e, '=')[0], 
    value: valueMap(std.join('=', std.split(e, '=')[1:]))
  },
  std.split(dotEnv, '\n')
);

local _std = {
  reduce:: function(reducer, array, initial)
    if std.length(array) > 1 
    then _std.reduce(reducer, array[1:], reducer(initial, array[0]))
    else reducer(initial, array[0]),
};


// ===========================================================================
// KUBERNETES
// ---------------------------------------------------------------------------
local k8s = {
  r:: _r,

  v1:: {
    local r(kind, namespace, name) = _r('v1', kind, namespace, name),
    r:: r,

    namespace:: function (name) r('Namespace', null, name),
    
    service:: function (namespace, name, deployment, ports) 
      r('Service', namespace, name) + {
      spec+: {
        ports: [ { port: p } for p in ports],
        selector+: {
          app: deployment.metadata.labels.app,
        },
        type: 'ClusterIP',
      }
    },

    serviceAccount:: function (namespace, name) r('ServiceAccount', namespace, name),

    hashedConfigMap:: function (configMap, namespace, name) configMap + 
      r('ConfigMap', namespace, name) + {
      local hash = std.md5(std.toString(configMap.data)),
      metadata+: {
        name: configMap.metadata.name + '-' + hash,
        [if namespace != null then 'namespace'] : namespace.metadata.name,
      }
    },

    secret:: function(namespace, name) r('Secret', namespace, name) + {
      data+: {}
    },
  }
};


// ===========================================================================
// KUBERNETES / APPS
// ---------------------------------------------------------------------------
local apps_v1 = {
  local r(kind, namespace, name) = _r('apps/v1', kind, namespace, name),
  r:: r,

  deployment:: function(namespace, name, replicas=1) r('Deployment', namespace, name) + {
    metadata+: { labels+: { app: name  } },
    spec+: {
      replicas: replicas,
      selector+: {
        matchLabels+: {
          app: name,
        },
      },
      template+: {
        metadata+: {
          labels+: {
            app: name,
          },
        },
      },
    },
  },
};


// ===========================================================================
// TEKTON / TRIGGERS
// ---------------------------------------------------------------------------

local tekton = {
  triggers:: {
    v1alpha1:: {
      r:: function(kind, namespace, name) k8s.r(
        'triggers.tekton.dev/v1alpha1', kind, namespace, name),

      sshKey:: function (namespace, name, sshPrivateKey) k8s.v1.r('Secret', 
        namespace, name) + {
        metadata+: {
          annotations+: {
            'tekton.dev/git-0': 'github.com'
          }
        },
        type: 'kubernetes.io/ssh-auth',
        data: {
          'ssh-privatekey': std.base64(sshPrivateKey),
          # This is non-standard, but its use is encouraged to make this more secure.
          # If it is not provided then the git server's public key will be requested
          # with `ssh-keyscan` during credential initialization.
          # 'known_hosts': std.base64(),
        }
      }
    }
  }
};


// ===========================================================================
// KANIKO
// ---------------------------------------------------------------------------
local kaniko = {
  cache:: function(namespace, images = [], size = '15Gi', 
    storageClassName='default') {

    local pvcName = 'kaniko-base-image-cache',

    pvc: k8s.v1.r('PersistentVolumeClaim', namespace, pvcName) + {
      spec+: {
        accessModes: ['ReadWriteMany'],
        storageClassName: storageClassName,
        resources: { requests: { storage: size } }
      }
    },

    warmerJob: k8s.r('batch/v1', 'Job', namespace, 'kaniko-warmer') + {
      spec+: {
        # automatically delete finished job after 100 seconds
        ttlSecondsAfterFinished: 100,
        backoffLimit: 0,
        template: {
          spec: {
            restartPolicy: 'Never',
            volumes: [{
              name: 'kaniko-cache',
              persistentVolumeClaim: { claimName: pvcName }
            }],
            containers: [{
              name: 'kaniko-warmer',
              image: 'gcr.io/kaniko-project/warmer:latest',
              args: ["--cache-dir=/cache"] + std.map(function(i) '--image=%s' % [i], images),
              volumeMounts: [{
                name: 'kaniko-cache',
                mountPath: '/cache'
              }]
            }],
          }
        },
      }
    }
  }
};


// ===========================================================================
// NETWORK
// ---------------------------------------------------------------------------
local network = {
  ingressRuleFirstPort:: function(hostname, service) {
    host: hostname,
    http+: {
      paths+: [{
        path: '/',
        backend: {
          serviceName: service.metadata.name,
          servicePort: service.spec.ports[0].port,
        }
      }]
    }
  },

  v1beta1:: {
    local r(kind, namespace, name) = k8s.r('networking.k8s.io/v1beta1', 
      kind, namespace, name),  

    ingress:: function(namespace, name, hostname, clusterIssuerName) r('Ingress', namespace, name) + {
      metadata+: {
        annotations+: {
          'kubernetes.io/ingress.class': 'nginx',
          # 'nginx.ingress.kubernetes.io/rewrite-target': '/',
          'cert-manager.io/cluster-issuer': clusterIssuerName,
        }
      },
      spec: {
        [if clusterIssuerName != null then 'tls']+: [{
          hosts: [ hostname ],
          secretName: 'tls-' + name,
        }],
        rules: [],
      },
    }
  }
};

// ===========================================================================
// (EXPORT)
// ---------------------------------------------------------------------------
{
  namespaceFrom:: namespaceFrom,
  nameFrom:: nameFrom,
  volumeFromSealedSecret:: volumeFromSealedSecret,
  environmentVariablesFromConfigMap:: environmentVariablesFromConfigMap,
  environmentVariablesFromSealedSecret:: environmentVariablesFromSealedSecret,
  nameValuePairsFromDotEnv:: nameValuePairsFromDotEnv,

  std:: _std,  
  
  v1:: k8s.v1,
  r:: k8s.r,

  apps:: {
    v1:: apps_v1
  },

  network:: network,

  tekton:: tekton,
  kaniko:: kaniko,
  
  # deployment:: deployment,
  # httpProbe:: httpProbe,
  # ingress:: ingress,
  # secret:: secret,
  # ingressRuleFirstPort:: ingressRuleFirstPort,
  # resources:: resources,
  # configMap:: configMap,
  # sealedSecret:: sealedSecret,
  # importSealedSecret:: importSealedSecret,
  # envFromSecretName:: envFromSecretName,
  # volumeFromConfigMap:: volumeFromConfigMap,
  # volumeFromSealedSecret:: volumeFromSealedSecret,
  # environmentVariablesFromConfigMap:: environmentVariablesFromConfigMap,
  # environmentVariablesFromSealedSecret:: environmentVariablesFromSealedSecret,
  # hashedConfigMap:: hashedConfigMap,
  # job:: job,
  
  version:: '0.4.0',
}

// ===========================================================================
// DEPRECATED
// ---------------------------------------------------------------------------
/*
local secret(namespace, name) = {
  apiVersion: 'v1',
  kind: 'Secret',
  metadata+: {
    name: name,
    namespace: namespace.metadata.name,
  },
  data+: {}
};

local deployment(namespace, name, replicas=1) = {
  apiVersion: 'apps/v1',
  kind: 'Deployment',
  metadata+: {
    namespace: namespace.metadata.name,
    name: name,
    labels+: {
      app: name,
    }
  },
  spec+: {
    replicas: replicas,
    selector+: {
      matchLabels+: {
        app: name,
      },
    },
    template+: {
      metadata+: {
        labels+: {
          app: name,
        },
      },
    },
  },
};

local ingress(namespace, name, hostname, clusterIssuerName) = {
  apiVersion: 'networking.k8s.io/v1beta1',
  kind: 'Ingress',
  metadata+: {
    namespace: namespace.metadata.name,
    name: name,
    annotations: {
      'kubernetes.io/ingress.class': 'nginx',
      # 'nginx.ingress.kubernetes.io/rewrite-target': '/',
      'cert-manager.io/cluster-issuer': clusterIssuerName,
    }
  },
  spec: {
    [if clusterIssuerName != null then 'tls']+: [{
      hosts: [ hostname ],
      secretName: 'tls-' + name,
    }],
    rules: [],
  },
};

local resources(memoryLimit = null, cpuLimit = null, memoryRequest = memoryLimit, cpuRequest = cpuLimit) = {
  limits: {
    [if memoryLimit != null then 'memory'] : memoryLimit,
    [if cpuLimit != null then 'cpu'] : cpuLimit,
  },
  requests: {
    [if memoryRequest != null then 'memory'] : memoryRequest,
    [if cpuRequest != null then 'cpu'] : cpuRequest,
  },
};

local envFromSecretName(name, secretName, key) = {
  name: name,
  valueFrom: { 
    secretKeyRef: { 
      name: secretName,
      key: key,
    },
  },
};



local volumeFromConfigMap(name, configMap) = {
  name: name,
  configMap: {
    name: configMap.metadata.name,
  },
};

local volumeFromSealedSecret(name, sealedSecret) = {
  name: name,
  secret: {
    secretName: sealedSecret.spec.template.metadata.name,
  }
};


local sealedSecret(namespace, name) = {
  kind: "SealedSecret",
  apiVersion: "bitnami.com/v1alpha1",
  metadata: {
    "name": name,
    "namespace": namespace.metadata.name,
  },
  "spec": {
    "template": {
      "metadata": {
        "name": name,
        "namespace": namespace.metadata.name,
      },
    },
  },
};


local httpProbe(path, port = 80, periodSeconds = 10) = {
  httpGet: {
    path: path,
    port: port,
    # httpHeaders:
    # - name: Custom-Header
    #   value: Awesome
  },
  periodSeconds: periodSeconds,
};

local importSealedSecret(sealedSecret, namespace = null) = sealedSecret + {
  metadata+: {
    [if namespace != null then 'namespace'] : namespace.metadata.name,
  },
  spec+: {
    template+: {
      metadata+: {
        [if namespace != null then 'namespace'] : namespace.metadata.name,
      },
    },
  },
};

local job(namespace, name) = {
  apiVersion: 'batch/v1',
  kind: 'Job',
  metadata+: {
    name: name,
    namespace: namespace.metadata.name,
  },
  spec+: {
    template+: {
      spec+: {
        restartPolicy: 'Never',
      }
    },
    backoffLimit: 0,
  }
};

local route(service, hostname = null, middlewares = [], context = null) = {
  kind: 'Rule',
  # match: 'Host(`' + hostname + '`)' + (if context != null then ' && PathPrefix(`' + context + '`)' else ''),
  match: (if hostname != null then 'HeadersRegexp(`X-Forwarded-Host`, `' + hostname + '`)' else '') + (if hostname != null && context != null then ' && ' else '') + (if context != null then 'PathPrefix(`' + context + '`)' else ''),
  middlewares: [ { name: m.metadata.name } for m in middlewares ],
  services: [
    {
      kind: 'Service',
      name: service.metadata.name,
      port: service.spec.ports[0].port,
    },
  ],
};

*/