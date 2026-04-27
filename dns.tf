resource "dnsimple_zone" "zones" {
  for_each = {
    alphachen_dev         = "alphachen.dev"
    arbitrary_definitions = "arbitrarydefinitions.com"
    chislan_family        = "chislan.family"
    islan_me              = "islan.me"
    kejadlen_dev          = "kejadlen.dev"
    overthinking_club     = "overthinking.club"
    issues_cooking        = "issues.cooking"
  }

  name   = each.value
  active = true
}

resource "dnsimple_zone_record" "chislan_family_subdomains" {
  for_each = {
    auth      = { zone = dnsimple_zone.zones["chislan_family"], ip = local.lotus_land_story.ip_address }
    birdnetpi = { zone = dnsimple_zone.zones["chislan_family"], ip = local.lotus_land_story.ip_address }
    docs      = { zone = dnsimple_zone.zones["chislan_family"], ip = local.lotus_land_story.ip_address }
    files     = { zone = dnsimple_zone.zones["chislan_family"], ip = local.lotus_land_story.ip_address }
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
    auth    = local.lotus_land_story.ip_address
    git     = local.lotus_land_story.ip_address
    grafana = local.lotus_land_story.ip_address
    hey     = local.lotus_land_story.ip_address
    quire   = local.lotus_land_story.ip_address
    monica  = local.ramble_hard.ip_address
    social  = local.ramble_hard.ip_address
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

resource "dnsimple_zone_record" "overthinking_club" {
  for_each = toset(["", "*"])

  zone_name = dnsimple_zone.zones["overthinking_club"].name
  name      = each.key
  value     = "138.199.218.242"
  type      = "A"
}

resource "dnsimple_zone_record" "github" {
  zone_name = dnsimple_zone.zones["kejadlen_dev"].name
  type      = "TXT"
  name      = "_github-pages-challenge-kejadlen"
  value     = "083e1baf52b9ff89a4fef9328a16aa"
}

resource "dnsimple_zone_record" "low_quality_transcripts" {
  zone_name = dnsimple_zone.zones["kejadlen_dev"].name
  name      = "low-quality-transcripts"
  value     = "kejadlen.github.io"
  type      = "CNAME"
}

resource "dnsimple_zone_record" "issues_cooking_github" {
  for_each = {
    a_0    = { type = "A", value = "185.199.108.153" }
    a_1    = { type = "A", value = "185.199.109.153" }
    a_2    = { type = "A", value = "185.199.110.153" }
    a_3    = { type = "A", value = "185.199.111.153" }
    aaaa_0 = { type = "AAAA", value = "2606:50c0:8000::153" }
    aaaa_1 = { type = "AAAA", value = "2606:50c0:8001::153" }
    aaaa_2 = { type = "AAAA", value = "2606:50c0:8002::153" }
    aaaa_3 = { type = "AAAA", value = "2606:50c0:8003::153" }
  }

  zone_name = dnsimple_zone.zones["issues_cooking"].name
  name      = ""
  value     = each.value.value
  type      = each.value.type
}

resource "dnsimple_zone_record" "issues_cooking_github_challenge" {
  zone_name = dnsimple_zone.zones["issues_cooking"].name
  name      = "_github-pages-challenge-kejadlen"
  value     = "1c2996553fef1408b8d060f4976696"
  type      = "TXT"
}

resource "dnsimple_zone_record" "issues_cooking_github_www" {
  zone_name = dnsimple_zone.zones["issues_cooking"].name
  name      = "www"
  value     = "kejadlen.github.io"
  type      = "CNAME"
}

resource "dnsimple_zone_record" "issues_cooking_goatcounter" {
  zone_name = dnsimple_zone.zones["issues_cooking"].name
  name      = "stats"
  value     = "low-quality-transcripts.goatcounter.com"
  type      = "CNAME"
}

resource "dnsimple_zone_record" "issues_cooking_google" {
  zone_name = dnsimple_zone.zones["issues_cooking"].name
  name      = ""
  value     = "google-site-verification=iK-byKyu145FcOGAzPFLurySmxidNiZ4vTX_HJcs1c0"
  type      = "TXT"
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
