function valid(k, v, quoted) {
  if (k == "view") return quoted && v ~ /^(inline|rail|auto|off)$/
  if (k == "action_bar") return quoted && v ~ /^(always|mouse|never)$/
  if (k == "restore" || k == "force_send") return !quoted && v ~ /^(true|false)$/
  if (k == "lines") return !quoted && v ~ /^[1-9][0-9]*$/
  return 0
}
BEGIN {
  d["view"] = "inline"
  d["action_bar"] = "always"
  d["restore"] = "true"
  d["lines"] = "1000"
  d["force_send"] = "false"
}
/^[ \t]*\[/ { table = 1 }
table { next }
{
  line = $0
  sub(/^[ \t]+/, "", line)
  if (!match(line, /^[A-Za-z0-9_-]+[ \t]*=[ \t]*/)) next
  k = line
  sub(/[ \t]*=.*/, "", k)
  v = substr(line, RLENGTH + 1)
  quoted = v ~ /^"/
  if (quoted) {
    if (!match(v, /^"[^"\\]*"/)) next
    rest = substr(v, RLENGTH + 1)
    v = substr(v, 2, RLENGTH - 2)
  } else {
    match(v, /^[^ \t\r#]*/)
    rest = substr(v, RLENGTH + 1)
    v = substr(v, 1, RLENGTH)
  }
  if (rest !~ /^[ \t\r]*(#.*)?$/) next
  if (valid(k, v, quoted)) d[k] = v
}
END { print d[key] }
