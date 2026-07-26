# The tailnet policy file, in full — tailscale_acl owns the whole document, not a fragment of
# it. Held in policy.hujson rather than a heredoc so it stays a reviewable file with comments
# intact (HuJSON survives the round trip) and so the admin console's "External reference" can
# point straight at it.
#
# overwrite_existing_content is deliberately NOT set. Without it the provider refuses to apply
# until the live policy has been imported, which is the guardrail that stops a first apply from
# silently replacing a tailnet's real policy with whatever this file happens to contain:
#
#   pass-cli run --env-file secrets.env -- tofu import tailscale_acl.this acl
#
# The tests block in policy.hujson is evaluated server-side when the document is written, so a
# failing test aborts the apply and the tailnet keeps its previous policy. Plan does not submit
# the document and so does not catch it — a green plan is not evidence the tests pass.
resource "tailscale_acl" "this" {
  acl = file("${path.module}/policy.hujson")
}
