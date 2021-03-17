# k8s.libsonnet

Building blocks for kubernetes resource descriptions based on jsonnet.

## Get started

Save the library locally.

``` bash
# Version 0.5.2
wget https://raw.githubusercontent.com/muxmuse/k8s.libsonnet/0.5.2/k8s.libsonnet

# Latest
wget https://raw.githubusercontent.com/muxmuse/k8s.libsonnet/main/k8s.libsonnet
```

Then use it like so:

``` jsonnet
local k8s = import './k8s.libsonnet';

{
  namespace:: k8s.namespace('my-namespace'),

  local name = 'my-app',
  local hostname = 'dev.my-app.com',
  
  ssRegCred: import './regcred.sealed-secret.k8s.json',
  ssEnv: import './env.sealed-secret.k8s.json',

  deployment: k8s.apps.v1.deployment($.namespace, name) + {
    spec+: { template+: { spec+: { 
      imagePullSecrets: [{ name: k8s.nameFrom($.ssRegCred) }],
      containers: [{
        env: [] + 
          k8s.nameValuePairsFromDotEnv(importstr './env') + 
          k8s.environmentVariablesFromSealedSecret($.ssEnv),
        name: 'app',
        image: 'docker.io/my-org/my-image:latest',
      }]
    } } }
  },

  service: k8s.v1.service($.namespace, name, $.deployment, [80]),

  ingress: k8s.network.v1beta1.ingress($.namespace, name, hostname, 'letsencrypt-production') + {
    spec+: {
      rules+: [
        k8s.network.ingressRuleFirstPort(hostname, $.service)
      ]
    }
  },
}
```

## API Documentation

### Append a hash to the name of a k8s object.

Updating ConfigMaps or Secrets without changing their name will not restart dependend deployments. `withHashPostfixedName` appends the hash of the content of a given field to the name of the k8s object.

``` jsonnet
{ 
  metadata: { name: 'my-name' }, 
  data: 'my-data' 
} 
+ k8s.withHashPostfixedName(field='data')

# results in 

{
   "data": "my-data",
   "metadata": {
      "name": "my-name-5fe46afb72359e0ff0151f793a27f367"
   }
}
```

### g8s ("gates") continuous deployment paradigm

Given a software project where the executable are OCI images that shall run on kubernetes and given the source code is managed with git, this section describes a convenient way of managing configurations, images and source code such that

1. Every change is tracked in git
2. Builds based on public base images are reproducible
3. Configuration is separated from source
4. Security patches of public base images are enforced (but rollbacks remain possible)
5. Configurations are readable
6. Integrations and deployments are executed within the kubernetes cluster

Technology used for the test implementation
- tekton
- bitnami sealed secrets
- cert-manager
- github
- azure container registry
- jsonnet
- kubecfg

Source repositories
```
app/
  Dockerfile
  ...

configuration/
  production/
    index.k8s.jsonnet
    init.k8s.jsonnet
  ...
```

1. There is one source repository per app that contains all files needed to produce an OCI image. The Dockerfile is at root level.

2. There is one configuration repository containing all the configurations of the app and the definition of the ci/cd pipelines. Each configuration corresponds to one directory and one kubernetes namespace. The directory contains all files that vary between configurations but at least the two files: init.k8s.jsonnet and index.k8s.jsonnet such that `kubecfg update init.k8s.jsonnet` creates all resources that do not change between deployments (e.g. the namespace and the ci/cd resources, also service accounts, etc.) and `kubecfg update index.k8s.jsonnet` creates or updates only the app itself (including services, ingress). A repeated call to `kubecfg update index.k8s.jsonnet` must not change anything in the cluster.

3. The app repository may have multiple branches representing quality gates (e.g. staging, production). Webhooks are configured such that a build is triggered on every push to those branches. The resulting images are tagged with the branch name and pushed to the image registry.

4. Deployments are triggered by pushes to the the image registry or by pushes to the configuration repository.
