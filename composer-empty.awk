/^─(.*─)?[[:space:]]*$/ { above = below; below = NR }
{ line[NR] = $0 }
END { exit !(below && above && below == above + 2 && line[above + 1] ~ /^❯[[:space:]]*$/) }
