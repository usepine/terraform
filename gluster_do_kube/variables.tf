variable "digitalocean_cluster" {

}

variable "storage_node_count" {
  default = 3
}

variable "storage_node_size" {
  default = "s-1vcpu-2gb"
}

variable "storage_node_name_suffix" {
  default = "storage-pool"
}

variable "volume_region" {
  default = "fra1"
}

variable "volume_name_prefix" {

}

variable "volume_size" {

}

variable "namespace" {

}

variable "selector_label" {
  default = "usepine/storage-selector"
}

variable "selector_label_value" {
  default = "gluster"
}