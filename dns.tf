resource "dnsimple_zone" "zones" {
  for_each = {
    alphachen_dev         = "alphachen.dev"
    arbitrary_definitions = "arbitrarydefinitions.com"
    chislan_family        = "chislan.family"
    islan_me              = "islan.me"
    kejadlen_dev          = "kejadlen.dev"
  }

  name   = each.value
  active = true
}

resource "dnsimple_zone_record" "chislan_family_subdomains" {
  for_each = {
    auth      = { zone = dnsimple_zone.zones["chislan_family"], ip = local.lotus_land_story.ip_address }
    birdnetpi = { zone = dnsimple_zone.zones["chislan_family"], ip = local.lotus_land_story.ip_address }
    docs      = { zone = dnsimple_zone.zones["chislan_family"], ip = local.lotus_land_story.ip_address }
  }

  zone_name = each.value.zone.name
  name      = each.key
  value     = each.value.ip
  type      = "A"
}

# TODO
# - mitmproxy?
resource "dnsimple_zone_record" "kejadlen_dev_subdomains" {
  for_each = {
    auth   = local.lotus_land_story.ip_address
    git    = local.lotus_land_story.ip_address
    hey    = local.lotus_land_story.ip_address
    monica = local.ramble_hard.ip_address
    social = local.ramble_hard.ip_address
  }

  zone_name = dnsimple_zone.zones["kejadlen_dev"].name
  name      = each.key
  value     = each.value
  type      = "A"
}

resource "dnsimple_zone_record" "kejadlen_dev_amazon_ses" {
  for_each = {
    dkim_0 = {
      type  = "CNAME"
      name  = "x76j3kgcyouqomw2q3iuxfrulgqmqdy3._domainkey"
      value = "x76j3kgcyouqomw2q3iuxfrulgqmqdy3.skim.amazonses.com"
    }
    dkim_1 = {
      type  = "CNAME"
      name  = "ruslnm7oo3s3t2xofmbn6brinbzeacxj._domainkey"
      value = "ruslnm7oo3s3t2xofmbn6brinbzeacxj.skim.amazonses.com"
    }
    dkim_2 = {
      type  = "CNAME"
      name  = "kew5ewv4jhf6a6x2t2tncmfts4os7vfy._domainkey"
      value = "kew5ewv4jhf6a6x2t2tncmfts4os7vfy.skim.amazonses.com"
    }
    ses_mx = {
      type     = "MX"
      name     = "ses"
      value    = "feedback-smtp.us-west-2.amazonses.com"
      priority = 10
    }
    ses_txt = {
      type  = "TXT"
      name  = "ses"
      value = "v=spf1 include:amazonses.com ~all"
    }
  }

  zone_name = dnsimple_zone.zones["kejadlen_dev"].name
  type      = each.value.type
  name      = each.value.name
  value     = each.value.value
  priority  = try(each.value.priority, null)
}

resource "dnsimple_zone_record" "kejadlen_dev_smtp2go" {
  for_each = {
    em539125             = "return.smtp2go.net"
    "s539125._domainkey" = "dkim.smtp2go.net"
    link                 = "track.smtp2go.net"
  }

  zone_name = dnsimple_zone.zones["kejadlen_dev"].name
  name      = each.key
  value     = each.value
  type      = "CNAME"
}

module "fastmail" {
  for_each = {
    alphachen_dev         = dnsimple_zone.zones["alphachen_dev"]
    arbitrary_definitions = dnsimple_zone.zones["arbitrary_definitions"]
    chislan_family        = dnsimple_zone.zones["chislan_family"]
    islan_me              = dnsimple_zone.zones["islan_me"]
    kejadlen_dev          = dnsimple_zone.zones["kejadlen_dev"]
  }

  source = "./modules/fastmail"
  zone   = each.value
}
