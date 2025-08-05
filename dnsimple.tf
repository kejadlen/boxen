# https://www.fastmail.help/hc/en-us/articles/360060591153-Manual-DNS-configuration

resource "dnsimple_zone" "islan_me" {
  name   = "islan.me"
  active = true
}

resource "dnsimple_zone_record" "islan_me_mx" {
  for_each = {
    mx1 = { value = "in1-smtp.messagingengine.com", priority = 10 }
    mx2 = { value = "in2-smtp.messagingengine.com", priority = 20 }
  }

  zone_name = dnsimple_zone.islan_me.name
  name      = ""
  value     = each.value.value
  type      = "MX"
  priority  = each.value.priority
}

resource "dnsimple_zone_record" "islan_me_spf" {
  zone_name = dnsimple_zone.islan_me.name
  name      = ""
  value     = "v=spf1 include:spf.messagingengine.com ?all"
  type      = "TXT"
}

resource "dnsimple_zone_record" "islan_me_dkim" {
  for_each = toset(["fm1", "fm2", "fm3"])

  zone_name = dnsimple_zone.islan_me.name
  name      = "${each.key}._domainkey"
  value     = "${each.key}.islan.me.dkim.fmhosted.com"
  type      = "CNAME"
}

resource "dnsimple_zone_record" "islan_me_dmarc" {
  zone_name = dnsimple_zone.islan_me.name
  name      = "_dmarc"
  value     = "v=DMARC1; p=none;"
  type      = "TXT"
}

resource "dnsimple_zone_record" "islan_me_autodiscover" {
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

  zone_name = dnsimple_zone.islan_me.name
  name      = "_${each.key}._tcp"
  value     = "${each.value.weight} ${each.value.port} ${each.value.target}"
  priority  = each.value.priority
  type      = "SRV"
}

