output "node_ips" {
  value = data.digitalocean_droplet.gluster.*.ipv4_address_private
}

output "rwx_storageclass" {
  value = kubernetes_storage_class.gluster.metadata.0.name
}
