function sgr(params,    n, a, i, p) {
  n = split(params, a, ";")
  if (n == 0) { faint = 0; bg = 0; return }
  for (i = 1; i <= n; i++) {
    p = a[i] + 0
    if (p == 0) { faint = 0; bg = 0 }
    else if (p == 2) faint = 1
    else if (p == 22) faint = 0
    else if (p == 49) bg = 0
    else if ((p >= 40 && p <= 47) || (p >= 100 && p <= 107)) bg = 1
    else if (p == 38 || p == 48 || p == 58) {
      if (p == 48) bg = 1
      if (a[i + 1] == "5") i += 2
      else if (a[i + 1] == "2") i += 4
    }
  }
}
function emit(s) {
  if (s == "") return
  plain[NR] = plain[NR] s
  if (!faint) solid[NR] = solid[NR] s
  if (bg) shaded[NR] = 1
}
function blank(s) { return s ~ /^[[:space:]]*$/ }
BEGIN { nbsp = "\302\240" }
{
  s = $0
  sub(/\r$/, "", s)
  gsub(nbsp, " ", s)
  plain[NR] = ""
  solid[NR] = ""
  while (match(s, /\033(\[[0-9;:?<=>]*[ -\/]*[@-~]|\][^\007\033]*(\007|\033\\)|.)/)) {
    emit(substr(s, 1, RSTART - 1))
    seq = substr(s, RSTART, RLENGTH)
    if (seq ~ /^\033\[[0-9;:]*m$/) sgr(substr(seq, 3, length(seq) - 3))
    s = substr(s, RSTART + RLENGTH)
  }
  emit(s)
  if (plain[NR] ~ /^─(.*─)?[[:space:]]*$/) { above = below; below = NR; prompt = 0 }
  else if (plain[NR] ~ /^[[:space:]]*›/ && NR > below) prompt = NR
}
END {
  if (prompt) {
    first = prompt
    for (last = prompt; last < NR && (shaded[prompt] ? shaded[last + 1] : !blank(plain[last + 1])); last++);
  } else if (above && below > above + 1) {
    first = above + 1
    last = below - 1
  } else exit 1
  text = ""
  for (i = first; i <= last; i++) text = text solid[i] "\n"
  sub(/^[[:space:]]*(❯|›|>)?/, "", text)
  exit !blank(text)
}
