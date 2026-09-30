# VKS Deployment Guide for VCF 9.0.0 Air-Gapped Environments

## Introduction
The complete procedure to install a VKS cluster with additional VKS Standard Package add-ons within an air-gapped environment involves the following significant steps:

- Copy the relevant files and binaries to be moved to the air-gapped environment.
- Enable the Supervisor.
- Upload Kubernetes release OVAs to a Content Library.
- Create vSphere Namespace(s) for VKS Clusters(s).
- Configure the air-gapped Admin host in the air-gapped environment. 
- Mirror an Enterprise OCI registry with the relevant container images for the platform. 
- Install the relevant Supervisor Services.
- Deploy the VKS Cluster(s).
- Deploy the VKS Standard Packages on the VKS Cluster(s).

The data flow of packages, binaries, and images between the internet-connected and air-gapped environment can be summarized by the picture below -

![image](ocireg-dataflow.png)

## Terminology
* **Bastion Host** A host (preferably a Linux VM) that is connected to the Internet or has access to download packages, binaries, and images from the Internet.
* **Admin Host** A host (preferably a Linux VM) within the air-gapped environment without internet access. The Admin host generally has network connectivity to all the hosts in the air-gapped environment. Files downloaded from the Internet to the Bastion host are transferred to the Admin Machine, and administrators can use it to interact with the platform.
* **VCF CLI** A plugin-based CLI that is used to interact with the Supervisor and VKS clusters. Starting with vSphere/Supervisor 9.0.0, the VCF CLI unifies and replaces the functionality previously provided by the `kubectl-vsphere` plugin and the Tanzu CLI.
* **VKS Standard Packages** VKS Standard Packages enable administrators and users to add and manage standard services and add-ons on VKS clusters using the VCF CLI or Carvel Custom Resources.

## Prerequisites
* This guide is for VCF / VVF 9.0.0 deployments, and an **Enterprise OCI-compliant registry** is assumed to be available in the air-gapped environment and accessible by all platform nodes, including the admin host. The registry must be accessible over HTTPS. The certificate can be signed by a trusted certificate authority or self-signed.
* **Note** If an Enterprise registry is unavailable in the air-gapped environment, please visit this [document](/airgapped/air-gapped-harbor.md) to install and configure Harbor as Bootstrap and Platform registries.
* For VCF / VVF 9.1.1 and later deployments, please follow this [document](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/managing-vsphere-kubernetes-service/deploying-vks-in-airgappen-environment/deploy-vks-in-airgapped-environments.html) to leverage VCF download tool and VCF Software Depot for VKS deployments in airgapped environments.
* For VCF / VVF 9.1.0 deployments, the distribution docker registry in VCF Software Depot can be used as the OCI compliant registry to host OCI images for system services, please visit this [document](/airgapped/air-gapped-vcf91.md) to follow the VKS deployment guide for Air-Gapped Environments.
* For VCF / VVF deployments based on releases earlier than 9.0.0, please visit the legacy [VKS Deployment Guide for Air-Gapped Environments](/airgapped/air-gapped.md).

## Bill of Materials
The table below provides sample hostnames and versions used throughout the document for easy reference -

|Component|Version|Sample Hostname (where applicable)|
|---------|-------|----------------------------------|
|Bastion Host|Ubuntu 24.04.4|bastion.internet.lab.test|
|Admin Host (Air-gapped)|Ubuntu 24.04.4 (identical to the Bastion Host)|admin.env1.lab.test|
|vCenter|9.0.0|vcenter.env1.lab.test|
|ESXi|9.0.0|esxi[0..xxx].env1.lab.test|
|Supervisor|9.0.0|supervisor0.env1.lab.test|
|Enterprise Registry||registry1.env1.lab.test|
|VKS cluster|v1.33.1|workload-vsphere-vks1|
|VKS Standard Package|v2025.6.17||
|VKS Service (VMware vSphere Kubernetes Service)|v3.3.1||

Additionally, it is crucial to have the following packages and binaries installed on both the Bastion and Admin Host - 
* `wget`
* `curl`
* `docker` (Preferably from the Docker website [https://docs.docker.com/engine/install/])
* `jq`
* `yq` (Some Linux distributions come with their implementation of yq. These packages are not the latest and/or provide the full functionalities. The newest version of the yq package can be downloaded from [https://github.com/mikefarah/yq/releases])
* `openssl` for certificate generation and validations. 
* `imgpkg` for pulling and pushing Carvel package images &mdash; see https://carvel.dev/imgpkg/docs/develop/install/#via-script-macos-or-linux
* Additional troubleshooting and diagnostic tools as needed. 

## 1. Download all required Plugins, Binaries, and Images
This document utilizes an Ubuntu 24.04.4-based Bastion host (**bastion.internet.lab.test**) for this stage. Below are the key plugins and packages that must be downloaded, each playing a critical role in the platform deployment process.

### 1a. Kubernetes Release OVA files
Kubernetes releases provide the Kubernetes software distribution for VKS clusters. VMware distributes Kubernetes releases as virtual machine templates, which you synchronize with the platform using a vCenter Content Library. Download the latest Kubernetes release files from https://wp-content.broadcom.com/v2/latest/. The versions to be downloaded may depend on the workload requirements. It would be best to download three or more of the latest versions. Follow the [official documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kubernetes-service/administering-kubernetes-releases-for-tkg-service-clusters/create-a-local-content-library-for-air-gapped-cluster-provisioning.html) to download the relevant Kubernetes release files for each version.

### 1b. VCF CLI and Plugins
While the VCF CLI and its plugins will be installed on the Bastion host (`bastion.internet.lab.test`), they must also be copied to the Admin Machine as part of the file transfer process. When this document was written, VCF CLI v9.0.0 was supported with vSphere / Supervisor v9.0.0. The steps below involve installing the VCF CLI on the Bastion host, which is necessary to download the VCF CLI plugins.

Since the Bastion host is internet-connected, follow the official documentation to [install the VCF CLI from a binary release](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9/installing-the-vcf-cli-in-internet-connected-environments/install-the-vcf-cli(3)/install-vcf-cli-plugins.html) (or, alternatively, [install the VCF CLI using a package manager](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9/installing-the-vcf-cli-in-internet-connected-environments/install-the-vcf-cli(3)/install-vcf-cli-using-package-managers.html) such as `apt` on Ubuntu). The steps below use the binary release method.

```bash
## Download the VCF CLI binary matching your OS/architecture
wget https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/v9.0.0/vcf-cli.tar.gz

## Extract the downloaded tarball
tar -xvf vcf-cli.tar.gz

## Move the VCF CLI to the Executable Path
sudo install ./vcf-cli-linux_amd64 /usr/local/bin/vcf

## Verify the installation
vcf version

## Sample output
version: v9.0.0
```

With the VCF CLI installed on the Bastion host, follow the [official documentation to install VCF CLI plugins](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9/installing-the-vcf-cli-in-internet-connected-environments/install-the-vcf-cli(3)/install-vcf-cli-plugins-copy.html) to identify and install the required plugin group. The `vmware-vcfcli/essentials` group provides the plugins needed to interact with the Supervisor and VKS clusters (e.g., `namespaces`, `cluster`, `kubernetes-release`, `package`). Note that the `addon` plugin, used to manage `AddonRepository` objects and add-on installs, was introduced in a later VCF CLI release than 9.0.0; this document uses the `package` plugin (Carvel `PackageRepository`/`InstalledPackage` model) instead, consistent with VCF CLI 9.0.0.

```bash
## Command to list all available plugin groups
vcf plugin group search --show-details

## Command to view the plugins included in a specific plugin group
vcf plugin group get vmware-vcfcli/essentials:v9.0.0

## Install the plugin group on the Bastion host
vcf plugin install --group vmware-vcfcli/essentials:v9.0.0

## Example: Install a single plugin (e.g., the package plugin) instead of a full group
vcf plugin install package

## Pull the downloaded plugins into a tarball using the following command
vcf plugin download-bundle --group vmware-vcfcli/essentials:v9.0.0 --plugin package --to-tar vcf-cli-plugins.tar.gz
```

### 1c. VKS Standard Packages
VKS Standard Packages enable administrators and users to use the VCF CLI or Carvel Custom Resources to add and manage standard services and add-ons on VKS clusters. With VKS Standard Packages, you can deploy various packages to VKS Clusters, such as cert-manager, Contour, Prometheus, Grafana, and more. Download the relevant bundle using the `imgpkg` binary installed on the Bastion host -

```bash
imgpkg copy -b projects.packages.broadcom.com/vsphere/supervisor/packages/2025.6.17/vks-standard-packages:v2025.6.17 --to-tar ./vks-standard-packages.tar --cosign-signatures
```

### 1d. Binaries and YAML files required for Supervisor Services
Supervisor Services are Carvel packages and are defined by their configuration file. The configuration file contains the reference to the image that holds the package manifest. As a prerequisite for migrating the Supervisor Services to the air-gapped registry, we need to extract the value of the image containing the package manifest. To do so, we can download the configuration YAML file from the Supervisor Services list and look for the following key - `spec.template.spec.fetch.imgpkgBundle[].image` for the Package object. For example, in the argocd.yaml configuration file for the ArgoCD Supervisor Service, the value is the image that would need to be migrated to the air-gapped environment. 

```yaml
...
---
apiVersion: data.packaging.carvel.dev/v1alpha1
kind: Package
metadata:
  creationTimestamp: null
  name: argocd-service.vsphere.vmware.com.1.0.0-24815986
spec:
  refName: argocd-service.vsphere.vmware.com
  releasedAt: "2025-05-08T08:32:37Z"
  template:
    spec:
      deploy:
      - kapp: {}
      fetch:
      - imgpkgBundle:
          image: projects.packages.broadcom.com/vsphere/supervisor/argocd-service/1.0.0/argocd-service:v1.0.0_vmware.1
...
```
For additional information and examples, please refer to [Steps 1, 2 and 3 of the official documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-supervisor-services-with-vsphere-iaas-control-plane/deploying-supervisor-services-from-a-private-container-image-registry/relocate-supervisor-services-to-a-private-registry.html) to relocate Supervisor Services to a private registry. While the official documentation refers to the `imgpkg` binary to perform the download function, this document uses the same `imgpkg` binary directly (rather than a CLI plugin), since it is now a standalone binary that must be installed as a prerequisite on both the Bastion and Admin hosts.

#### E.g., Download Contour Supervisor Service Binaries and associated YAML files.
When writing this document, the latest version of the Contour Supervisor Service is “v1.30.3”. Please refer to the Broadcom Support Portal to check for updated versions. Download the Contour Supervisor Service configuration YAML file as described above, and locate the value of the image from the file.

You can execute the following command from the Bastion host to download the image bundle as a tarball.

```bash
## Download Contour Binaries
imgpkg copy -b projects.packages.broadcom.com/vsphere/supervisor/packages/2025.6.17/vks-standard-packages@sha256:f67f7f6f7cd7533970c808c9d58e199d50a53afa107f9a7ebe30f7d9ddb186f1 --to-tar contour-v1.30.3.tar --cosign-signatures
```
Perform similar steps for other Supervisor Services that must be installed in the air-gapped environment. 

The Supervisor Service configuration YAML files are not linked directly in this document. Instead, download the configuration YAML file for each Supervisor Service version listed below from the [Broadcom Support Portal](https://support.broadcom.com): after logging in, navigate to **My Downloads** and search for *vSphere Supervisor Services*.

The table below provides the sample list of Supervisor Services that can be downloaded and installed on the platform -

|Service Name|Type|Version|
|------------|----|-------|
|VKS Service|Core|v3.3.1|
|Contour|Standard|v1.30.3|
|Harbor|Standard|v2.13.1|
|Consumption Interface|Standard|9.0.0|
|ExternalDNS|Standard|v0.16.1|
|ArgoCD|Standard|v1.0.0|

### Summary
The following files, binaries, and packages have been successfully downloaded in this section and **must be transferred to the Admin host**. 
* Kubernetes Release OVA files. 
* The installed VCF CLI binary (`/usr/local/bin/vcf`) and plugin cache directory (`~/.local/share/vcf-cli/`) from the Bastion host (see step 1b). The `vcf-cli-plugins.tar.gz` bundle is not required for the Admin host but may be kept for future reference.
* VKS Standard Packages (vks-standard-packages.tar). This file can be gzipped if needed. 
* Supervisor Service packages and Yaml Files.

## 2. Enable the Supervisor
Using the steps and directions in the official [documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/vsphere-supervisor-installation-and-configuration.html), configure the required networking, storage policies, and profiles and enable the Supervisor on `vcenter.env1.lab.test`.

## 3. Create a Kubernetes release content library and upload Kubernetes release images
The Kubernetes release OVAs downloaded on the Bastion host and copied to the Admin host must be uploaded to a Content library within the vCenter. Before proceeding, a local content library must be created. The "Create a Local Content Library (for Air-Gapped Cluster Provisioning)" [documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kubernetes-service/administering-kubernetes-releases-for-tkg-service-clusters/create-a-local-content-library-for-air-gapped-cluster-provisioning.html) provides instructions on creating and importing Kubernetes Release (Kr) images into the content library, including details on the files (downloaded previously in step 1a) that need to be uploaded to the local content library. 

## 4. Create vSphere Namespace(s) for VKS Clusters(s)
If not already created, a vSphere namespace should be created. Refer to "[Create and Configure a vSphere Namespace on the Supervisor](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/vsphere-supervisor-installation-and-configuration/configuring-and-managing-vsphere-namespaces/create-and-configure-a-vsphere-namespace.html)" to configure the vSphere Namespace.

## 5. Configure Admin host
The Admin host (**admin.env1.lab.test**) is essential to the next deployment stage. It performs crucial tasks such as uploading binaries and image bundles to the repository, deploying VKS Clusters, and deploying VKS Standard Packages on the VKS Clusters. As the control center, this machine enables effective deployment management and repository coordination. This document uses an `Ubuntu 24.04.4` machine with *Docker* installed on the Admin Machine. If Docker isn't installed, please review the [official documentation](https://docs.docker.com/engine/install/ubuntu/) for installation guidance. The instructions may have to be modified for an airgapped installation. The recommended system configuration is as follows:
* CPU: 2 vCPUs
* Memory: 4 GB
* Storage: 150–200 GB of free space

Note: Before moving forward, verify that all the files mentioned in the Summary section in Step 1 have been successfully copied to the Admin host.

### 5a. Download and Install kubectl CLI
`kubectl` is the command-line tool used to interact with Kubernetes clusters. It allows users to manage and inspect resources within a Kubernetes environment. The `kubectl-vsphere` plugin bundle is still the source used to obtain the `kubectl` binary for the Admin host, even though login to the Supervisor and VKS clusters is now performed using the VCF CLI (see step 5b below).

You can download the `kubectl` CLI to your Admin machine by accessing the Supervisor Cluster Kube-API server endpoint UI or using the command below.

```bash
wget https://<Supervisor-KubeAPI-Endpoint>/wcp/plugin/linux-amd64/vsphere-plugin.zip --no-check-certificate

## Sample Command:
wget https://supervisor0.env1.lab.test/wcp/plugin/linux-amd64/vsphere-plugin.zip --no-check-certificate

## After downloading the vsphere-plugin.zip file, use the following commands to unzip it and add the binaries to the executable path.
unzip ./vsphere-plugin.zip
cd ./bin
sudo install kubectl /usr/local/bin/kubectl

## Verify the version by executing the below commands
kubectl version
```

### 5b. Login to Supervisor
If not logged in, log in to the Supervisor using the VCF CLI (copied over to the Admin host along with the files transferred in step 1; see step 5d for verification), instead of the `kubectl-vsphere` plugin or the Tanzu CLI.

Before running VCF CLI commands, download and install the vCenter trusted root CA certificates so that the VCF CLI can trust the certificate of the Supervisor.

```bash
# Download vCenter trusted root CA certificates with below command or download via the "Download trusted root CA certificates" link on the vCenter login UI.
wget https://<vCenter-IP>/certs/download.zip --no-check-certificate

# Unzip and install the trusted root CA certificates
unzip download.zip -d .
cd certs/lin
for f in *; do cp $f /etc/ssl/certs/$f.crt; done

# Connect to vSphere Namespace using the VCF CLI
vcf context create <context-name> --endpoint <SupervisorAPIEndpoint> --username <sso_username> --type k8s
vcf context use <context-name>:<namespace-name>

## Sample Command to login and use the context of namespace ns01 for VKS cluster deployment later.
vcf context create supervisor1 --endpoint https://supervisor0.env1.lab.test --username administrator@vsphere.local --type k8s
vcf context use supervisor1:ns01
```

### 5c. Add the Enterprise Registry certificate to the Admin host Trust Store (Optional)
To ensure the Admin machine trusts the registry, we must add the Enterprise registry certificate (E.g., the contents saved in file `registry1.crt`) to the Trust Store. This step is optional and required only when using a certificate not signed by a trusted Certificate authority (e.g., a self-signed certificate).

```bash
## Ubuntu specific example
sudo cp registry1.crt /usr/local/share/ca-certificates 
sudo update-ca-certificates
```

Once the certificate has been added to the trust store, log in to the registry endpoint using Docker.

```bash
## Restart Docker Service
sudo systemctl reload docker
sudo systemctl restart docker

## Command to Login to Harbor Supervisor Service Endpoint
docker login registry1.env1.lab.test

## Enter the username and password when prompted. The expected output is shown below:
=====
WARNING! Your password will be stored unencrypted in /root/.docker/config.json.
Configure a credential helper to remove this warning. See
https://docs.docker.com/engine/reference/commandline/login/#credential-stores

Login Succeeded
=====
```
### 5d. Verify the VCF CLI installation
The VCF CLI binary and the required plugins were already installed on the Bastion host in step 1b. Since the Admin host is identical to the Bastion host, the installed `vcf` binary (`/usr/local/bin/vcf`) and the local plugin cache directory (`~/.local/share/vcf-cli/`) are simply carried over as part of the same file transfer to the Admin host — there is no need to re-download, re-install, or upload the VCF CLI plugin bundle to the Enterprise registry. Once the files have been copied over, verify the installation on the Admin host.

```bash
## Verify the VCF CLI version
vcf version

## Sample output
version: v9.0.0

## Verify that the required plugins (e.g., the package plugin) are installed
vcf plugin list

## Sample output
  NAME                DESCRIPTION                             TARGET  VERSION  STATUS
  cluster             Kubernetes cluster operations           k8s     v3.3.1   installed
  kubernetes-release  Kubernetes release operations           k8s     v3.3.1   installed
  namespaces          Discover vSphere Supervisor namespaces  k8s     v9.0.0   installed
  package             Manage packages                         k8s     v3.3.1   installed
```

## 6. Add the Enterprise Registry certificate to the Supervisor (Optional)
The Supervisor must trust the Enterprise registry certificate. This step is optional and required only when using a certificate not signed by a trusted Certificate authority (e.g., a self-signed certificate). To perform this step, navigate to Workload Management -> Supervisor -> Configure -> Container Registries. Click on Add Registry. 

![image](add-cert0.png)

Input the Registry host URL, TLS Certificate of the registry (the content of `registry1.crt`), Username, and Password. Note that while the UI states that the Username and Password are optional, they are currently mandatory.

![image](add-cert1.png)

## 7. Upload Packages to the Enterprise registry
Create two projects/folders, with public access, within the registry to upload -
* All the supervisor services (e.g., `sup-services`) must be installed on the supervisor. The steps may vary depending on the registry vendor and version.
* The VKS Standard Packages will be installed on the VKS cluster (e.g. `vks-packages`). The steps may vary depending on the registry vendor and version.

### 7a. Upload VKS Standard Packages to the Enterprise Registry
The VKS Standard Packages bundle, downloaded in Step 1c, must be uploaded to the Enterprise registry using the `imgpkg` binary. 

```bash
## Sample Command
imgpkg copy --tar ./vks-standard-packages.tar --to-repo registry1.env1.lab.test/vks-packages/packages/2025.6.17/vks-standard-packages --cosign-signatures --registry-response-header-timeout 600s
```

### 7b. Upload Supervisor Services to the Enterprise Registry
All the Supervisor Services image bundle binaries downloaded in Step 1d must be uploaded to the Enterprise registry. Follow [steps 4 and 5 from the official documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-supervisor-services-with-vsphere-iaas-control-plane/deploying-supervisor-services-from-a-private-container-image-registry/relocate-supervisor-services-to-a-private-registry.html) to complete this critical step.

```bash
## Sample Command
imgpkg copy --tar contour-v1.30.3.tar --to-repo registry1.env1.lab.test/sup-services/contour --cosign-signatures
```

Additionally, the corresponding Supervisor Service YAML needs to be updated with the new Enterprise registry valid location -

```yaml
# Contour.yaml
...
template:
  spec:
    fetch:
    - imgpkgBundle:
        image: registry1.env1.lab.test/sup-services/contour@sha256:f67f7f6f7cd7533970c808c9d58e199d50a53afa107f9a7ebe30f7d9ddb186f1
...
```
Perform these steps for all the Supervisor Services that were previously downloaded. Once completed, add the required Supervisor Services to the Supervisor using the [steps provided in the documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-supervisor-services-with-vsphere-iaas-control-plane/deploying-supervisor-services-from-a-private-container-image-registry/install-and-use-the-supervisor-service.html).

## 8. Deploy VKS Cluster(s)

### 8a. Update the VKS Service to the latest version
When writing the documentation, the latest VKS Service (VMware vSphere Kubernetes Service) was v3.3.1. Since each VKS Service release introduces additional features and fixes, we must apply these updates to make the new features and fixes available. Follow the relevant sections in the [documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kubernetes-service/installing-and-upgrading-the-tkg-service/upgrade-the-tkg-service-version.html) to complete the upgrade. 

### 8b. Create a Workload Cluster certificate (Optional)
The VKS cluster nodes and `kapp` controllers running on the VKS cluster must trust the Enterprise registry's SSL certificate. This step is optional and not required if a trusted certificate authority signs the Enterprise registry’s certificate. The following [product documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/provisioning-tkg-service-clusters/using-the-cluster-v1beta1-api/v1beta1-example-cluster-with-additional-trusted-ca-certificates-for-ssl-tls.html) link provides details on how to perform this step. 

```bash
## Sample command
 base64 -w 0 registry1.crt | base64 -w 0 
```

```yaml
## additional-ca-1.yaml
apiVersion: v1
data:
  ## The value of additional-ca-1 is the output of the above command.
  additional-ca-1: TFMwdExTMUNSGlSzZ3Jaa...VVNVWkpRMEMwdExTMHRDZz09
kind: Secret
metadata:
  name: workload-vsphere-vks1-user-trusted-ca-secret
  namespace: ns01
type: Opaque
```

### 8c. Deploy a Workload Cluster
Deploying a VKS Cluster (using an Ubuntu image). Review each section at a minimum and adjust the necessary fields as needed. Refer to the [“Using the Cluster v1beta1 API” documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/provisioning-tkg-service-clusters/using-the-cluster-v1beta1-api.html) for more configuration options.
* Control Plane Size:  
** Nodes: 1 or 3 for high availability 
** vCPUs: 4, Memory: 16GB, Storage: 50GB
* Worker Node Size: 
** Nodes: 3 for a standard-size stack 
** vCPUs: 4, Memory: 16GB, Storage: 50GB

While `v1beta1` provides numerous configuration options, the following additional variables may be added for a default `podSecurityStandard` and additional certificate `trust.` 
```yaml
## vksConfig.yaml
...
    variables:
      - name: podSecurityStandard
        value:
          audit: restricted
          auditVersion: latest
          enforce: privileged
          enforceVersion: latest
          warn: privileged
          warnVersion: latest
#      Uncomment the below lines if using an Enterprise registry. See above section 8b 
#      - name: trust
#        value: 
#          additionalTrustedCAs:
#          - name: additional-ca-1
...
```

Since the Admin host is already logged in to the Supervisor namespace context using the VCF CLI (see step 5b), the cluster can be created directly with `kubectl`.

```bash
## If using Enterprise registry with a private certificate. Please take a look at section 8b.
kubectl apply -f <additional-ca-1.yaml> -n ns01

## Deploy VKS cluster
kubectl create -f <vksConfig.yaml> -n ns01

## Command to check the status of Cluster Creation
kubectl get cluster -n ns01
kubectl describe cluster workload-vsphere-vks1 -n ns01
```

### 8d. Deploy VKS Standard Package(s) on Workload Cluster
VKS Standard Packages can be deployed from the VKS Standard repository using the `package` plugin of the VCF CLI from the Admin host. We will use `cert-manager` as an example to demonstrate the ease of deploying these packages. We must first switch the VCF CLI context to the VKS cluster and add the package repository before installing cert-manager. (Note: the `addon` plugin and its `AddonRepository`/`vcf addon ...` commands were introduced in a VCF CLI release later than 9.0.0 and are not used in this guide.)

Log in to the VKS Cluster using the VCF CLI from the Admin machine, instead of the `kubectl-vsphere` plugin.
```bash
## Create a new context with VKS cluster info
vcf context create <context-name> --endpoint https://supervisor0.env1.lab.test --username <sso_username> --type k8s --workload-cluster-name <vks-cluster-name> --workload-cluster-namespace <vks-cluster-namespace>
## Switch the active VCF CLI context to the target VKS workload cluster
vcf context use <context-name>:<vks-cluster-name>

## Sample Command
vcf context create sv-vks --endpoint https://supervisor0.env1.lab.test --username administrator@vsphere.local --type k8s --workload-cluster-name workload-vsphere-vks1 --workload-cluster-namespace ns01
vcf context use sv-vks:workload-vsphere-vks1
```

Add the package repository, pointing at the `vks-packages` project uploaded to the Enterprise registry in step 7a.
```bash
## Command to add Package repository
vcf package repository add vks-standard --url <registry-fqdn>/<project-name>/packages/2025.6.17/vks-standard-packages:v2025.6.17 --namespace tkg-system

## Sample Command
vcf package repository add vks-standard --url registry1.env1.lab.test/vks-packages/packages/2025.6.17/vks-standard-packages:v2025.6.17 --namespace tkg-system
```

Ensure that the package repository is reconciled successfully. 
```bash
vcf package repository list -n tkg-system 

## Sample Output
  NAME          SOURCE                                                                                             STATUS
  vks-standard  (imgpkg) registry1.env1.lab.test/vks-packages/packages/2025.6.17/vks-standard-packages:v2025.6.17  Reconcile succeeded

vcf package available list -n tkg-system

## Sample Output
  NAME                                            DISPLAY-NAME
  autoscaler.kubernetes.vmware.com                autoscaler
  cert-manager.kubernetes.vmware.com              cert-manager
  cert-manager.tanzu.vmware.com                   cert-manager
  contour.tanzu.vmware.com                        contour
  external-dns.tanzu.vmware.com                   external-dns
  fluent-bit.tanzu.vmware.com                     fluent-bit
  grafana.tanzu.vmware.com                        grafana
  harbor.tanzu.vmware.com                         harbor
  prometheus.tanzu.vmware.com                     prometheus
  vsphere-pv-csi-webhook.tanzu.vmware.com         vsphere-pv-csi-webhook
```

Install cert-manager using the below commands - 
```bash
## Command to List the versions of Cert-Manager Available
vcf package available list cert-manager.kubernetes.vmware.com -A

## Sample Output
  NAMESPACE   NAME                           VERSION                 RELEASED-AT
  tkg-system  cert-manager.kubernetes.vmware.com  1.17.2+vmware.1-vks.1  2025-06-17 12:00:00 +0000 UTC

## Command to install the cert-manager in a new namespace
kubectl create namespace <namespaceName>
vcf package install cert-manager --package cert-manager.kubernetes.vmware.com --namespace <namespaceName> --version <1.17.2+vmware.1-vks.1>

## Sample Command
kubectl create namespace ns01
vcf package install cert-manager --package cert-manager.kubernetes.vmware.com --namespace ns01 --version 1.17.2+vmware.1-vks.1

## Verify the cert-manager pods
kubectl get pods -n cert-manager

## Sample Output
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-6778554f58-jhvb8              1/1     Running   0          54s
cert-manager-cainjector-575468965b-xrzf4   1/1     Running   0          54s
cert-manager-webhook-567f6945f-8m8d6       1/1     Running   0          54s
```

Note: In the sample commands provided, the cert-manager application will be deployed in the `namespaceName` namespace, with all required pods created in the `cert-manager` namespace. If a namespace named `cert-manager` already exists, the package deployment will use that existing namespace. If the package installation fails, label the `cert-manager` namespace with `pod-security.kubernetes.io/enforce=privileged` and delete all the ReplicaSets under the `cert-manager` namespace. This will prompt the deployment to recreate the ReplicaSets and the necessary pods.
