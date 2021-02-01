# k8s.libsonnet

Building blocks for kubernetes resource descriptions based on jsonnet.

## Get started

Save the library locally.

``` bash
# Version 0.5.0
wget https://raw.githubusercontent.com/muxmuse/k8s.libsonnet/0.5.0/k8s.libsonnet

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
{ data: 'my-data' } + k8s.withHashPostfixedName(field='data')
```