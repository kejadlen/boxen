# https://www.fastmail.help/hc/en-us/articles/360060591153-Manual-DNS-configuration

# Standard Mail
resource "dnsimple_zone_record" "mx" {
  for_each = {
    mx1 = { value = "in1-smtp.messagingengine.com", priority = 10 }
    mx2 = { value = "in2-smtp.messagingengine.com", priority = 20 }
  }

  zone_name = var.zone.name
  name      = ""
  value     = each.value.value
  type      = "MX"
  priority  = each.value.priority
}

# Webmail Login Portal
resource "dnsimple_zone_record" "webmail" {
  zone_name = var.zone.name
  name      = "mail"
  value     = "mail.fastmail.com"
  type      = "CNAME"
}

# DKIM
resource "dnsimple_zone_record" "dkim" {
  for_each = toset(["fm1", "fm2", "fm3"])

  zone_name = var.zone.name
  name      = "${each.key}._domainkey"
  value     = "${each.key}.${var.zone.name}.dkim.fmhosted.com"
  type      = "CNAME"
}

# SPF
resource "dnsimple_zone_record" "spf" {
  zone_name = var.zone.name
  name      = ""
  value     = "v=spf1 include:spf.messagingengine.com ?all"
  type      = "TXT"
}

# DMARC
resource "dnsimple_zone_record" "dmarc" {
  zone_name = var.zone.name
  name      = "_dmarc"
  value     = "v=DMARC1; p=none;"
  type      = "TXT"
}

# Client email auto-discovery
resource "dnsimple_zone_record" "autodiscover" {
  for_each = {
    submission   = { priority = 0, weight = 0, port = 0, target = "." }
    submissions  = { priority = 0, weight = 1, port = 465, target = "smtp.fastmail.com" }
    imap         = { priority = 0, weight = 0, port = 0, target = "." }
    imaps        = { priority = 0, weight = 1, port = 993, target = "imap.fastmail.com" }
    pop3         = { priority = 0, weight = 0, port = 0, target = "." }
    pop3s        = { priority = 10, weight = 1, port = 995, target = "pop.fastmail.com" }
    jmap         = { priority = 0, weight = 1, port = 443, target = "api.fastmail.com" }
    autodiscover = { priority = 0, weight = 1, port = 443, target = "autodiscover.fastmail.com" }
  }

  zone_name = var.zone.name
  name      = "_${each.key}._tcp"
  value     = "${each.value.weight} ${each.value.port} ${each.value.target}"
  priority  = each.value.priority
  type      = "SRV"
}

