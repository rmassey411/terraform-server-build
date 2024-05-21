#===================================================================
# Terraform version
#===================================================================
terraform {
  required_version = ">= 1.3.9"

  ### Terraform will keep track of the state of this VM in Consul.
  ### THIS PATH MUST BE UNIQUE!!!
  backend "consul" {
    address = "consul.k8s.mynet.local:8501"
    path    = "terraform/Operations/SED-REPLACE-ME"
    scheme  = "https"
  }

  required_providers {
    ### To find what version a Terraform provider has, comment out the
    ### version, and re-run `terraform init` and look for what's "Installed".
    consul = {
      source  = "hashicorp/consul"
      version = "~> 2.20.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 2.24.0"
    }
    vsphere = {
      source  = "hashicorp/vsphere"
      version = "~> 2.6.1"
    }
  }
}

#===================================================================
# Terraform Variables
#===================================================================
variable "vm_hostname" { default = "test-vm" }

#===================================================================
# Terraform Providers
#===================================================================
###
provider "consul" {
  address        = "consul.k8s.mynet.local:8501"
  datacenter     = "dc1"
  insecure_https = true
  scheme         = "https"
}

provider "vault" {
  address = "https://${data.consul_service.vault.service[0].address}:${data.consul_service.vault.service[0].port}"
}

provider "vsphere" {
  allow_unverified_ssl = false
  password             = data.vault_generic_secret.terraform_vsphere.data["password"]
  user                 = data.vault_generic_secret.terraform_vsphere.data["username"]
  vsphere_server       = "vcenter.vmware.mynet.local"
}

#===================================================================
# Data
#===================================================================
### Contact the Consul server and tell me the active vault node
data "consul_service" "vault" {
  name = "vault"
  tag  = "active"
}

### How Terraform authenticates via SSH into the server.
data "vault_generic_secret" "terraform_ssh" {
  path = "terraform/ssh"
}

### How Terraform authenticates into vSphere.  Stored in Vault.
data "vault_generic_secret" "terraform_vsphere" {
  path = "terraform/vsphere"
}

### Where Terraform is gonna do all its stuff in vSphere
### https://registry.terraform.io/providers/hashicorp/vsphere/latest/docs
data "vsphere_datacenter" "dc" {
  name = "Main Campus"
}

data "vsphere_compute_cluster" "cluster" {
  name          = "Production"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "vsan_datastore" {
  name          = "myDatastore"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  name          = "Templates/ubuntu_2204_template"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "network" {
  name          = "192.168.1.0%2f22"
  datacenter_id = data.vsphere_datacenter.dc.id
}

#===================================================================
# Terraform Resources
#===================================================================

### Create the VM
resource "vsphere_virtual_machine" "SED-REPLACE-ME" {
  name                 = var.vm_hostname
  datastore_id         = data.vsphere_datastore.vsan_datastore.id
  resource_pool_id     = data.vsphere_compute_cluster.cluster.resource_pool_id
  folder               = "MyTeam/Terraformed"
  num_cpus             = 2
  memory               = 4096
  guest_id             = data.vsphere_virtual_machine.template.guest_id
  clone {
    customize {
      dns_server_list = ["192.168.1.230", "192.168.1.231"]
      dns_suffix_list = ["vmware.mynet.local", "k8s.mynet.local", "mynet.local"]
      ipv4_gateway    = "192.168.1.1"
      linux_options {
        host_name = var.vm_hostname
        domain    = "mynet.local"
        time_zone = "America/New_York"
      }
      network_interface {
        ipv4_address = "127.0.0.1"
        ipv4_netmask = 24
      }
    }
    linked_clone  = false
    template_uuid = data.vsphere_virtual_machine.template.id
  }
  connection {
    host        = self.default_ip_address
    type        = "ssh"
    user        = "toweragent"
    private_key = data.vault_generic_secret.terraform_ssh.data["sshkey"]
  }
  disk {
    unit_number      = 0
    label            = "${var.vm_hostname}.vmdk"
    size             = data.vsphere_virtual_machine.template.disks[0].size
    thin_provisioned = data.vsphere_virtual_machine.template.disks[0].thin_provisioned
    eagerly_scrub    = data.vsphere_virtual_machine.template.disks[0].eagerly_scrub
  }
  network_interface {
    network_id   = data.vsphere_network.network.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }
}



###
