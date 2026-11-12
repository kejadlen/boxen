{
  # Fixed so the Caddyfile can trust it; podman assigns subnets on creation otherwise.
  caddy = "10.89.0.0/24";
  # Fixed so miniflux can trust Caddy's address on it. Podman assigns from the
  # bottom of 10.89.0.0/16, so the top stays clear.
  rss = "10.89.255.0/24";
}
