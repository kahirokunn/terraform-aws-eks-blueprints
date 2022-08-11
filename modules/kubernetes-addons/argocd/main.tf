module "helm_addon" {
  source              = "../helm-addon"
  helm_config         = local.helm_config
  irsa_config         = null
  addon_context       = var.addon_context
  kubernetes_timeouts = var.kubernetes_timeouts

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_namespace_v1" "this" {
  count = try(local.helm_config["create_namespace"], true) && local.helm_config["namespace"] != "kube-system" ? 1 : 0
  metadata {
    name = local.helm_config["namespace"]
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# ArgoCD App of Apps Bootstrapping (Helm)
# ---------------------------------------------------------------------------------------------------------------------
resource "helm_release" "argocd_application" {
  for_each = { for k, v in var.applications : k => merge(local.default_argocd_application, v) if merge(local.default_argocd_application, v).type == "helm" }

  name      = each.key
  chart     = "${path.module}/argocd-application/helm"
  version   = "1.0.0"
  namespace = local.helm_config["namespace"]

  # Application Meta.
  set {
    name  = "name"
    value = each.key
  }

  set {
    name  = "project"
    value = each.value.project
  }

  # Source Config.
  set {
    name  = "source.repoUrl"
    value = each.value.repo_url
  }

  set {
    name  = "source.targetRevision"
    value = each.value.target_revision
  }

  set {
    name  = "source.path"
    value = each.value.path
  }

  set {
    name  = "source.helm.releaseName"
    value = each.key
  }

  dynamic "set" {
    for_each = toset(each.value.add_on_application ? ["any"] : [])
    content {
      name = "source.helm.values"
      value = yamlencode(module.helm_values[k].merged)
    }
  }

  dynamic "set" {
    for_each = toset(each.value.add_on_application == false ? ["any"] : [])
    content {
      name = "source.helm.values"
      value = yamlencode(module.helm_values[k].merged)
    }
  }

  # Destination Config.
  set {
    name  = "destination.server"
    value = each.value.destination
  }

  depends_on = [module.helm_addon]
}

# ---------------------------------------------------------------------------------------------------------------------
# ArgoCD App of Apps Bootstrapping (Kustomize)
# ---------------------------------------------------------------------------------------------------------------------
resource "kubectl_manifest" "argocd_kustomize_application" {
  for_each = { for k, v in var.applications : k => merge(local.default_argocd_application, v) if merge(local.default_argocd_application, v).type == "kustomize" }

  yaml_body = templatefile("${path.module}/argocd-application/kubectl/application.yaml.tftpl",
    {
      name                 = each.key
      namespace            = each.value.namespace
      project              = each.value.project
      sourceRepoUrl        = each.value.repo_url
      sourceTargetRevision = each.value.target_revision
      sourcePath           = each.value.path
      destinationServer    = each.value.destination
    }
  )

  depends_on = [module.helm_addon]
}

# ---------------------------------------------------------------------------------------------------------------------
# Private Repo Access
# ---------------------------------------------------------------------------------------------------------------------

resource "kubernetes_secret" "argocd_gitops" {
  for_each = { for k, v in var.applications : k => v if try(v.ssh_key_secret_name, null) != null }

  metadata {
    name      = "${each.key}-repo-secret"
    namespace = local.helm_config["namespace"]
    labels    = { "argocd.argoproj.io/secret-type" : "repository" }
  }

  data = {
    insecure      = lookup(each.value, "insecure", false)
    sshPrivateKey = data.aws_secretsmanager_secret_version.ssh_key_version[each.key].secret_string
    type          = "git"
    url           = each.value.repo_url
  }

  depends_on = [module.helm_addon]
}

module "helm_values" {
  for_each = { for k, v in var.applications : k => merge(local.default_argocd_application, v) if merge(local.default_argocd_application, v).type == "helm" }

  source  = "Invicton-Labs/deepmerge/null"
  version = "0.1.5"
  maps = [
    { repo_url = each.value.repo_url },
    each.value.values,
    local.global_application_values,
    each.value.add_on_application ? local.addon_config : {}
  ]
}
