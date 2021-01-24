locals {
  volume_size_G = var.volume_size

  # Breaks cycle between secret/service accounts
  secret_name = "${var.volume_name_prefix}-service-account-secret"

  # Commands to execute on every Gluster cluster node
  gluster_probe_commands = join(" ", [for droplet in data.digitalocean_droplet.gluster : "\"gluster peer probe ${droplet.ipv4_address_private}\""])
}

################################################
# DigitalOcean
################################################

resource "digitalocean_kubernetes_node_pool" "storage" {
  cluster_id = var.digitalocean_cluster.id
  name       = "${var.digitalocean_cluster.name}-${var.storage_node_name_suffix}"
  size       = var.storage_node_size
  auto_scale = false
  node_count = var.storage_node_count
  labels = {
    (var.selector_label) : var.selector_label_value
  }
}

resource "digitalocean_volume" "gluster" {
  count = digitalocean_kubernetes_node_pool.storage.node_count

  region = var.volume_region
  name   = "${var.volume_name_prefix}-${count.index}"

  size = local.volume_size_G

  description = "${var.volume_name_prefix}-${count.index}"
}

data "digitalocean_droplet" "gluster" {
  count = digitalocean_kubernetes_node_pool.storage.node_count

  id = digitalocean_kubernetes_node_pool.storage.nodes[count.index].droplet_id
}

################################################
# Kubernetes
################################################

resource "kubernetes_namespace" "gluster" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_persistent_volume_claim" "gluster" {
  count = digitalocean_kubernetes_node_pool.storage.node_count

  metadata {
    name      = "${var.volume_name_prefix}-pvc-${count.index}"
    namespace = kubernetes_namespace.gluster.metadata.0.name
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${local.volume_size_G}Gi"
      }
    }
    storage_class_name = "do-block-storage"
    selector {
      match_labels = {
        (var.selector_label) : var.selector_label_value
      }
    }
  }

  # Create and map PV to DO volumes. Our claims will refer to them by name
  depends_on = [kubernetes_persistent_volume.gluster]
}

resource "kubernetes_persistent_volume" "gluster" {
  count = digitalocean_kubernetes_node_pool.storage.node_count

  metadata {
    name = "${var.volume_name_prefix}-pv-${count.index}"
    labels = {
      (var.selector_label) : var.selector_label_value
    }
  }

  spec {
    storage_class_name = "do-block-storage"

    capacity = {
      storage = "${local.volume_size_G}Gi"
    }

    access_modes = ["ReadWriteOnce"]

    persistent_volume_source {
      # https://github.com/digitalocean/csi-digitalocean/blob/a6f5d96b1de397b86d04e13d956e9af116953cf1/examples/kubernetes/pod-single-existing-volume/README.md
      csi {
        driver        = "dobs.csi.digitalocean.com"
        fs_type       = "ext4"
        volume_handle = digitalocean_volume.gluster[count.index].id
        volume_attributes = {
          "com.digitalocean.csi/noformat" = "true"
        }
      }
    }

    node_affinity {
      required {
        node_selector_term {
          match_expressions {
            key      = var.selector_label
            operator = "In"
            values   = [var.selector_label_value]
          }
        }
      }
    }
  }
}

resource "kubernetes_storage_class" "gluster" {
  metadata {
    name = "${var.volume_name_prefix}-storageclass"
  }

  storage_provisioner = "gluster.org/glusterfs-simple"

  parameters = {
    namespace      = kubernetes_namespace.gluster.metadata.0.name
    forceCreate    = "true"
    brickrootPaths = join(",", [for droplet in data.digitalocean_droplet.gluster : "${droplet.ipv4_address_private}:/gfs/"])
  }
}

resource "kubernetes_secret" "gluster" {
  metadata {
    name      = "${var.volume_name_prefix}-service-account-secret"
    namespace = kubernetes_namespace.gluster.metadata.0.name

    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.gluster.metadata.0.name
    }
  }

  type = "kubernetes.io/service-account-token"

  depends_on = [kubernetes_service_account.gluster]
}

resource "kubernetes_service_account" "gluster" {
  metadata {
    name      = "${var.volume_name_prefix}-service-account"
    namespace = kubernetes_namespace.gluster.metadata.0.name
  }

  secret {
    name = local.secret_name
  }

  automount_service_account_token = true
}

resource "kubernetes_cluster_role" "gluster" {
  metadata {
    name = "${kubernetes_service_account.gluster.metadata.0.name}-role"
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumes"]
    verbs      = ["get", "list", "watch", "create", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumeclaims"]
    verbs      = ["get", "list", "watch", "update"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["events", "pods/exec"]
    verbs      = ["create", "update", "patch"]
  }

  rule {
    api_groups = [""]
    resources  = ["endpoints"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["services"]
    verbs      = ["get", "list", "watch", "create", "delete", "update", "patch"]
  }
}

resource "kubernetes_cluster_role_binding" "gluster" {
  metadata {
    name = "${kubernetes_service_account.gluster.metadata.0.name}-rolebinding"
  }

  role_ref {
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.gluster.metadata.0.name
    api_group = "rbac.authorization.k8s.io"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.gluster.metadata.0.name
    namespace = kubernetes_namespace.gluster.metadata.0.name
  }
}

resource "kubernetes_deployment" "provisioner" {
  metadata {
    name      = "${var.volume_name_prefix}-provisioner-deployment"
    namespace = kubernetes_namespace.gluster.metadata.0.name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app" = "${var.volume_name_prefix}-provisioner"
      }
    }

    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          "app" = "${var.volume_name_prefix}-provisioner"
        }
      }

      spec {
        automount_service_account_token = true
        service_account_name            = kubernetes_service_account.gluster.metadata.0.name
        container {
          image = "quay.io/external_storage/glusterfs-simple-provisioner:latest"
          name  = "${var.volume_name_prefix}-glusterfs-provisioner"
        }
      }
    }
  }
}

resource "null_resource" "gluster_peer_init" {
  count = digitalocean_kubernetes_node_pool.storage.node_count

  triggers = {
    command = local.gluster_probe_commands
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    command = <<EOC
      kubectl wait --for=condition=ready pod -l gluster=${var.volume_name_prefix}-${count.index} -n ${var.namespace}
      POD="$(kubectl get pod -l gluster=${var.volume_name_prefix}-${count.index} -n ${var.namespace} -o jsonpath='{.items[0].metadata.name}')"

      gluster_probe_commands=(${local.gluster_probe_commands})
      for cmd in "$${gluster_probe_commands[@]}"
      do
        kubectl exec "$POD" -n ${var.namespace} -- bash -c "$cmd"
      done
    EOC
  }

  depends_on = [kubernetes_replication_controller.gluster]
}

resource "kubernetes_replication_controller" "gluster" {
  count = digitalocean_kubernetes_node_pool.storage.node_count

  metadata {
    name      = "gluster-${count.index}"
    namespace = kubernetes_namespace.gluster.metadata.0.name
  }

  spec {
    selector = {
      gluster = "${var.volume_name_prefix}-${count.index}"
    }
    replicas = 1
    template {
      metadata {
        namespace = kubernetes_namespace.gluster.metadata.0.name
        labels = {
          "gluster"        = "${var.volume_name_prefix}-${count.index}"
          "glusterfs-node" = "pod"
        }
      }

      spec {
        host_network = true

        node_selector = {
          "doks.digitalocean.com/node-id" = digitalocean_kubernetes_node_pool.storage.nodes[count.index].id
        }

        container {
          image             = "gluster/gluster-centos:latest"
          image_pull_policy = "IfNotPresent"
          name              = "glusterfs"

          volume_mount {
            name       = "glusterfs-heketi"
            mount_path = "/var/lib/heketi"
          }
          volume_mount {
            name       = "glusterfs-run"
            mount_path = "/run"
          }
          volume_mount {
            name       = "glusterfs-lvm"
            mount_path = "/run/lvm"
          }
          volume_mount {
            name       = "glusterfs-etc"
            mount_path = "/etc/glusterfs"
          }
          volume_mount {
            name       = "glusterfs-logs"
            mount_path = "/var/log/glusterfs"
          }
          volume_mount {
            name       = "glusterfs-config"
            mount_path = "/var/lib/glusterd"
          }
          volume_mount {
            name       = "glusterfs-dev"
            mount_path = "/dev"
          }
          volume_mount {
            name       = "glusterfs-misc"
            mount_path = "/var/lib/misc/glusterfsd"
          }
          volume_mount {
            name       = "glusterfs-cgroup"
            mount_path = "/sys/fs/cgroup"
            read_only  = true
          }
          volume_mount {
            name       = "glusterfs-ssl"
            mount_path = "/etc/ssl"
            read_only  = true
          }
          volume_mount {
            name       = "gfs"
            mount_path = "/gfs"
          }
          security_context {
            capabilities {

            }
            privileged = true
          }
          readiness_probe {
            timeout_seconds       = 3
            initial_delay_seconds = 40
            exec {
              command = ["/bin/bash", "-c", "systemctl status glusterd.service"]
            }
            period_seconds    = 25
            success_threshold = 1
            failure_threshold = 15
          }
          liveness_probe {
            timeout_seconds       = 3
            initial_delay_seconds = 40
            exec {
              command = ["/bin/bash", "-c", "systemctl status glusterd.service"]
            }
            period_seconds    = 25
            success_threshold = 1
            failure_threshold = 15
          }
        }

        volume {
          name = "gfs"
          persistent_volume_claim {
            claim_name = "${var.volume_name_prefix}-pvc-${count.index}"
          }
        }

        volume {
          name = "glusterfs-heketi"
          host_path {
            path = "/var/lib/heketi"
          }
        }

        volume {
          name = "glusterfs-run"
        }

        volume {
          name = "glusterfs-lvm"
          host_path {
            path = "/run/lvm"
          }
        }

        volume {
          name = "glusterfs-etc"
          host_path {
            path = "/etc/glusterfs"
          }
        }

        volume {
          name = "glusterfs-logs"
          host_path {
            path = "/var/log/glusterfs"
          }
        }

        volume {
          name = "glusterfs-config"
          host_path {
            path = "/var/lib/glusterd"
          }
        }

        volume {
          name = "glusterfs-dev"
          host_path {
            path = "/dev"
          }
        }

        volume {
          name = "glusterfs-misc"
          host_path {
            path = "/var/lib/misc/glusterfsd"
          }
        }

        volume {
          name = "glusterfs-cgroup"
          host_path {
            path = "/sys/fs/cgroup"
          }
        }

        volume {
          name = "glusterfs-ssl"
          host_path {
            path = "/etc/ssl"
          }
        }
      }
    }
  }
}
