# Automation_Scripts-

Save: Save the script (e.g., as generate_dns_zones.sh).

Make Executable: chmod +x generate_dns_zones.sh

Run: Execute it with your FQDN and optional output files. The script will then prompt you interactively for each IP address.

Bash

./generate_dns_zones.sh -d yourcluster.example.org -o forward.zone -r reverse.zone

(Replace yourcluster.example.org, forward.zone, reverse.zone with your desired values).
