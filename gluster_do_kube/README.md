# GlusterFS on DigitalOcean Kubernetes

## Quick Start

```terraform
module "gluster" {
  source               = "git@github.com:usepine/terraform//gluster_do_kube?ref=main"
  digitalocean_cluster = digitalocean_kubernetes_cluster.cluster
  volume_size          = 10
  storage_node_count   = 3
  volume_name_prefix   = "myvol"
  namespace            = "myvol-gluster"

  providers = {
    kubernetes = kubernetes
  }
}
```

## Configuration

<details>
<summary>Available arguments</summary>

| Argument                   | Description                                                                                                                                                 | Default value              |
|----------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------|
| `digitalocean_cluster`     | Your [digitalocean_kubernetes_cluster](https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs/resources/kubernetes_cluster) resource |                            |
| `storage_node_count`       | The number of storage nodes (should be a number that can achieve quorum)                                                                                    | `3`                        |
| `storage_node_size`        | The DigitalOcean node type for storage nodes                                                                                                                | `s-1vcpu-2gb`              |
| `storage_node_name_suffix` | The name suffix for the storage node pool nodes                                                                                                             | `storage-pool`             |
| `volume_region`            | The storage node pool region                                                                                                                                | `fra1`                     |
| `volume_name_prefix`       | The volume name prefix. Will be used also in resulting storage class name.                                                                                  |                            |
| `volume_size`              | Volume size in GB                                                                                                                                           |                            |
| `namespace`                | The kubernetes namespace for the GlusterFS cluster resources                                                                                                |                            |
| `selector_label`           | The label to identify the storage nodes with                                                                                                                | `usepine/storage-selector` |
| `selector_label_value`     | The label value                                                                                                                                             | `gluster`                  |

</details>

## Provisioning DigitalOcean nodes with the Gluster client

The Kubernetes nodes managed by DigitalOcean need the GlusterFS client installed. Unfortunately,
there is no obvious way to install dependencies on these nodes.

To work around this issue, you could consider using a DaemonSet similar to this:

```terraform
#
# exec 'chroot /host' to get root access
# inspired by https://raesene.github.io/blog/2019/04/01/The-most-pointless-kubernetes-command-ever/
#
# This daemonset creates a pod on each node, which will:
#   - install gluster client
#   - stay alive in the background, allowing one shell access (via 'exec chroot /host') to the node
#
resource "kubernetes_daemonset" "noderoot" {
  metadata {
    name      = "noderoot"
    namespace = "default"
    labels = {
      purpose = "noderoot"
    }
  }

  spec {
    selector {
      match_labels = {
        purpose = "noderoot"
      }
    }

    template {
      metadata {
        labels = {
          purpose = "noderoot"
        }
      }

      spec {
        toleration {
          key    = "node-role.kubernetes.io/master"
          effect = "NoSchedule"
        }

        host_network = true
        host_pid     = true
        host_ipc     = true

        container {
          name  = "noderootpod"
          image = "busybox"
          security_context {
            privileged = true
          }
          volume_mount {
            mount_path = "/host"
            name       = "noderoot"
          }

          command = ["/bin/sh", "-c", "--"]
          args    = ["chroot /host /bin/sh -c 'apt update && apt install -yq glusterfs-client'; while true; do sleep 30; done;"]
        }

        volume {
          name = "noderoot"
          host_path {
            path = "/"
          }
        }
      }
    }
  }
}
```
