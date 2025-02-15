# https://www.fastmail.help/hc/en-us/articles/1500000280261-Setting-up-your-domain-MX-only#domain-registration
#
terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.18"
    }
  }
}

variable "domain" {
  type = object({
    id = string,
    domain = string,
  })
  nullable = false
}

resource "linode_domain_record" "fastmail_mx" {
  domain_id = var.domain.id

  for_each = {
    "in1-smtp.messagingengine.com" = 10
    "in2-smtp.messagingengine.com" = 20
  }

  record_type = "MX"
  priority    = each.value
  target      = each.key
}

resource "linode_domain_record" "fastmail_spf" {
  domain_id = var.domain.id

  name        = var.domain.domain
  record_type = "TXT"
  target      = "v=spf1 include:spf.messagingengine.com ?all"
}

resource "linode_domain_record" "fastmail_dkim" {
  domain_id = var.domain.id

  for_each = {
    "mesmtp._domainkey" = "mesmtp.${var.domain.domain}.dkim.fmhosted.com"
    "fm1._domainkey"    = "fm1.${var.domain.domain}.dkim.fmhosted.com"
    "fm2._domainkey"    = "fm2.${var.domain.domain}.dkim.fmhosted.com"
    "fm3._domainkey"    = "fm3.${var.domain.domain}.dkim.fmhosted.com"
  }

  name        = each.key
  record_type = "CNAME"
  target      = each.value
}

resource "linode_domain_record" "fastmail_dmarc" {
  domain_id = var.domain.id

  name        = "_dmarc.${var.domain.domain}"
  record_type = "TXT"
  target      = "v=DMARC1; p=none;"
}

resource "linode_domain_record" "fastmail_srv" {
  domain_id = var.domain.id

  for_each = {
    "submission" = { priority = 0, weight = 1, port = 587, target = "smtp.fastmail.com" }
    "imap"       = { priority = 0, weight = 0, port = 0, target = "." }
    "imaps"      = { priority = 0, weight = 1, port = 993, target = "imap.fastmail.com" }
    "pop3"       = { priority = 0, weight = 0, port = 0, target = "." }
    "pop3s"      = { priority = 10, weight = 1, port = 995, target = "pop.fastmail.com" }
    "jmap"       = { priority = 0, weight = 1, port = 443, target = "api.fastmail.com" }
  }

  service     = each.key
  record_type = "SRV"
  priority    = each.value.priority
  protocol    = "tcp"
  weight      = each.value.weight
  port        = each.value.port
  target      = each.value.target
}
