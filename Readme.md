# End to End Encryption Demo

## Deploying the Customer -> Preference -> Recommendation App

you can find the application described [here](https://redhat-developer-demos.github.io/istio-tutorial/istio-tutorial/1.1.x/2deploy-microservices.html#deploycustomer)

Deploy it with the following:

```shell
oc new-project demo

oc apply -f https://raw.githubusercontent.com/redhat-developer-demos/istio-tutorial/master/customer/kubernetes/Deployment.yml -n demo
oc apply -f https://raw.githubusercontent.com/redhat-developer-demos/istio-tutorial/master/customer/kubernetes/Service.yml -n demo
oc create route edge customer --service=customer -n demo

oc apply -f https://raw.githubusercontent.com/redhat-developer-demos/istio-tutorial/master/preference/kubernetes/Deployment.yml -n demo
oc apply -f https://raw.githubusercontent.com/redhat-developer-demos/istio-tutorial/master/preference/kubernetes/Service.yml -n demo

oc apply -f https://raw.githubusercontent.com/redhat-developer-demos/istio-tutorial/master/recommendation/kubernetes/Deployment.yml -n demo
oc apply -f https://raw.githubusercontent.com/redhat-developer-demos/istio-tutorial/master/recommendation/kubernetes/Service.yml -n demo
```

## Deploying cert-manager

[cert-manager](https://github.com/jetstack/cert-manager) is our certificate provisioning operator. It makes certificates a first class resource inside of OpenShift.

```shell
oc new-project cert-manager
oc label namespace cert-manager certmanager.k8s.io/disable-validation=true
oc apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v0.9.0/cert-manager-openshift.yaml
oc patch deployment cert-manager -n cert-manager -p '{"spec":{"template":{"spec":{"containers":[{"name":"cert-manager","args":[{"--v=2"},{"--cluster-resource-namespace=$(POD_NAMESPACE)"},{"--leader-election-namespace=$(POD_NAMESPACE)"},{"--dns01-recursive-nameservers=8.8.8.8:53"}]}]}}}}'
TO-TEST
```

## Deploying the Let's Encrypt cluster issuer

[Let's Encrypt](https://letsencrypt.org/) represent our CA for externally visible certificates (i.e. certificates that have to be trasuted by browser and OSs of our customers). 

```shell
export EMAIL=<your-lets-encrypt-email>
oc apply -f lets_encrypt_issuer/aws-credentials.yaml
export AWS_ACCESS_KEY_ID=$(oc get secret cert-manager-dns-credentials -n cert-manager -o jsonpath='{.data.aws_access_key_id}' | base64 -d)
export REGION=$(oc get nodes --template='{{ with $i := index .items 0 }}{{ index $i.metadata.labels "failure-domain.beta.kubernetes.io/region" }}{{ end }}')
export zoneid=$(oc get dns cluster -o jsonpath='{.spec.publicZone.id}')
envsubst < lets_encrypt_issuer/lets-encrypt-issuer.yaml | oc apply -f - -n cert-manager
```

## Deploying cert-utils-operator

[cert-utils-operator](https://github.com/redhat-cop/cert-utils-operator) provides some additional features to managing certificates, such as injection of certificates in routes.

```shell
oc new-project cert-utils-operator
helm fetch https://github.com/redhat-cop/cert-utils-operator/raw/master/helm/cert-utils-operator-0.0.1.tgz
helm template cert-utils-operator-0.0.1.tgz --namespace cert-utils-operator | oc apply -f - -n cert-utils-operator
```

## Secure the route

```shell
namespace=demo route=customer host=$(oc get route $route  -n $namespace -o jsonpath='{.spec.host}') envsubst < route/certificate.yaml | oc apply -f - -n demo
oc annotate route customer -n demo cert-utils-operator.redhat-cop.io/certs-from-secret=cert-manager-customer
```

## Create the internal CA issuer

We assume that services that are not exposed internally get their certificates from an internal issuer (external issuer usually have a cost based on the number of certificates). To simulate this situation we are going to use the internal CA issuer from cert-manager.

```shell
oc apply -f internal_issuer/internal-issuer.yaml -n cert-manager
```

## Create internal certificates

```shell
service=customer namespace=demo envsubst < internal_certificate/internal_cert.yaml | oc apply -f - -n demo;
service=preference namespace=demo envsubst < internal_certificate/internal_cert.yaml | oc apply -f - -n demo;
service=recommendation namespace=demo envsubst < internal_certificate/internal_cert.yaml | oc apply -f - -n demo;
```

## Mount certificates on the pods

Java applications use keystores and truststore.

```shell
oc annotate secret customer -n demo cert-utils-operator.redhat-cop.io/generate-java-keystores=true;
oc annotate secret preference -n demo cert-utils-operator.redhat-cop.io/generate-java-keystores=true;
oc annotate secret recommendation -n demo cert-utils-operator.redhat-cop.io/generate-java-keystores=true;

oc set volume deployment customer -n demo --add=true --type=secret --secret-name=customer --name=keystores --mount-path=/keystores --read-only=true
oc set volume deployment preference-v1 -n demo --add=true --type=secret --secret-name=preference --name=keystores --mount-path=/keystores --read-only=true
oc set volume deployment recommendation-v1 -n demo --add=true --type=secret --secret-name=recommendation --name=keystores --mount-path=/keystores --read-only=true

oc patch deployment customer -n demo -p '{"spec":{"template":{"spec":{"containers":[{"name":"customer","args":[{"-Djavax.net.ssl.keyStore=/keystores/keystore.jks"},{"-Djavax.net.ssl.keyStorePassword=changeme"},{"-Djavax.net.ssl.trustStore=/keystores/truststore.jks"},{"-Djavax.net.ssl.trustStorePassword=changeme"}]}]}}}}'
TO-TEST

oc patch deployment preference-v1 -n demo -p '{"spec":{"template":{"spec":{"containers":[{"name":"preference","args":[{"-Djavax.net.ssl.keyStore=/keystores/keystore.jks"},{"-Djavax.net.ssl.keyStorePassword=changeme"},{"-Djavax.net.ssl.trustStore=/keystores/truststore.jks"},{"-Djavax.net.ssl.trustStorePassword=changeme"}]}]}}}}'

oc patch deployment recommendation-v1 -n demo -p '{"spec":{"template":{"spec":{"containers":[{"name":"recommendation","args":[{"-Djavax.net.ssl.keyStore=/keystores/keystore.jks"},{"-Djavax.net.ssl.keyStorePassword=changeme"},{"-Djavax.net.ssl.trustStore=/keystores/truststore.jks"},{"-Djavax.net.ssl.trustStorePassword=changeme"}]}]}}}}'
```

## Make the route use and trust the new certificate

```shell
oc patch route customer -n demo -p '{"spec":{"tls":{"termination":"reencrypt"}}}'
oc annotate route customer -n demo cert-utils-operator.redhat-cop.io/destinationCA-from-secret=customer
```

## Install Reloader

When a certificate is renewed, the files will be updated on the container's file system. Unless the app is written to watch those files, we need to restart the application. We are going to make that happen with the [Reloader] operator

```shell
oc new-project reloader
helm repo add stakater https://stakater.github.io/stakater-charts
helm repo update
helm fetch stakater/reloader
helm template reloader-v0.0.37.tgz --namespace reloader | oc apply -f - -n reloader
TO-TEST

```

## Configure deployments to reload upon certificate change

```shell
oc annotate deployment customer -n demo secret.reloader.stakater.com/reload=customer;
oc annotate deployment preference-v1 -n demo secret.reloader.stakater.com/reload=preference;
oc annotate deployment recommendation-v1 -n demo secret.reloader.stakater.com/reload=recommendation;
```
