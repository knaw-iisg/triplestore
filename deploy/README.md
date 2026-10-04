# Deploying the public IISG knowledge graph

Three public services, one VPS (TransIP V4, `37.97.229.152`, Ubuntu 24.04 LTS):

| Hostname | Serves | Backed by |
|---|---|---|
| `sparql.zijdeman.nl` | the raw SPARQL endpoint | QLever, same as your local `qlever start` |
| `kb.zijdeman.nl` | the curated browsable UI | `iisg-kb-viewer`'s Flask app |
| `kg.zijdeman.nl` | QLever's own generic query UI (autocomplete SPARQL builder) | `qlever ui`, same as your local `http://localhost:7876/default` |

Caddy sits in front of both, doing automatic HTTPS (Let's Encrypt) and
reverse-proxying to each service on localhost. Nothing except 22/80/443 is
open to the internet -- QLever and the viewer are only reachable via Caddy.

Files in this directory, each copied to the VPS in the steps below:
- `Caddyfile` -> `/etc/caddy/Caddyfile`
- `kb-viewer.service` -> `/etc/systemd/system/kb-viewer.service`
- `firewall.sh` -> run once, directly

## 0. DNS

In whatever control panel manages `zijdeman.nl`'s DNS, add two `A` records
pointing at the VPS:

```
sparql.zijdeman.nl.   A   37.97.229.152
kb.zijdeman.nl.       A   37.97.229.152
kg.zijdeman.nl.       A   37.97.229.152
```

Give these a few minutes (or longer, depending on TTL) to propagate before
step 5 -- Caddy needs them resolving correctly to get certificates.

## 1. SSH in, basic setup

Working as a `sudo`-group user (here, `silk`), not root directly:

```bash
ssh silk@37.97.229.152
sudo apt update && sudo apt upgrade -y
sudo apt install -y docker.io python3-pip python3-venv
sudo usermod -aG docker silk   # log out/in once after this for it to take effect
```

## 2. Ship the already-built QLever index

The index was already built locally (~750MB, ~1 minute to build from
scratch if you ever need to) -- no need to re-run all seven ETL pipelines
on the VPS. Just sync the built index files up. **From your local machine**
(not the VPS):

```bash
cd /home/rey/git/triplestore
scp -C \
  Qleverfile Qleverfile-ui.yml \
  iisg.index* iisg.internal.index* iisg.meta-data.json \
  iisg.settings.json iisg.vocabulary.* \
  silk@37.97.229.152:~/triplestore/
```

(`rsync` is the better tool for repeat syncs -- incremental, resumable -- but
isn't installed by default everywhere; `scp` needs nothing extra and is fine
for this one-shot ~750MB copy. Install `rsync` on both ends later if this
becomes a recurring update.)

(Deliberately excludes `sources/` -- that's the 3.3GB of raw ETL output,
only needed for *re-indexing*, not for serving. Deliberately excludes the
log/metrics/UI-db files too; QLever regenerates those.)

## 3. Start QLever on the VPS

**Back on the VPS:** Ubuntu 24.04 blocks system-wide `pip install` (PEP 668),
so use a venv:

```bash
python3 -m venv ~/.venvs/qlever
~/.venvs/qlever/bin/pip install qlever
echo 'export PATH="$HOME/.venvs/qlever/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
cd ~/triplestore
```

Add two lines to `Qleverfile` before starting -- `[server] TIMEOUT` caps
how long a single public query can run (protects the box from one expensive
query), and `[runtime] RESTART_POLICY` makes the container survive a reboot:

```ini
[server]
...
TIMEOUT = 30s

[runtime]
...
RESTART_POLICY = unless-stopped
```

```bash
qlever start
qlever status   # confirm it's serving on localhost:7878
```

(If `docker` group membership from step 1 hasn't kicked in yet for this
shell, log out and back in first -- `qlever start` needs to run `docker`
commands without `sudo`.)

## 3b. Start QLever's own UI

This is the generic autocomplete SPARQL query builder that ships with
QLever -- distinct from `iisg-kb-viewer`. **First**, point its config at the
*public* SPARQL endpoint, not localhost -- this config's `baseUrl` is read
by each visitor's own browser JS, not resolved on the VPS, so it has to be
a URL the public can actually reach:

```bash
sed -i 's|baseUrl: http://localhost:7878|baseUrl: https://sparql.zijdeman.nl|' \
  ~/triplestore/Qleverfile-ui.yml
```

Then start it:

```bash
cd ~/triplestore
qlever ui
```

Unlike `qlever start`, `qlever ui` has no `RESTART_POLICY` setting -- patch
the container directly so it survives a reboot too:

```bash
docker update --restart=unless-stopped qlever.ui.iisg
```

## 4. Set up the viewer

**Back on the VPS:**

```bash
sudo useradd -r -s /usr/sbin/nologin kbviewer
sudo git clone https://github.com/knaw-iisg/iisg-kb-viewer /opt/iisg-kb-viewer
cd /opt/iisg-kb-viewer
sudo python3 -m venv .venv
sudo .venv/bin/pip install -r requirements.txt gunicorn
sudo chown -R kbviewer:kbviewer /opt/iisg-kb-viewer

sudo cp ~/triplestore/deploy/kb-viewer.service /etc/systemd/system/kb-viewer.service
sudo systemctl daemon-reload
sudo systemctl enable --now kb-viewer
sudo systemctl status kb-viewer   # confirm it's serving on localhost:5000
```

## 5. Install Caddy and the firewall

```bash
apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install -y caddy

cp /root/triplestore/deploy/Caddyfile /etc/caddy/Caddyfile
systemctl reload caddy

bash /root/triplestore/deploy/firewall.sh
```

## 6. Verify

```bash
curl -s https://sparql.zijdeman.nl \
  --data-urlencode "query=SELECT (COUNT(*) AS ?n) WHERE { GRAPH ?g { ?s ?p ?o } }" \
  -H "Accept: text/csv"
```

Then open `https://kb.zijdeman.nl` in a browser and confirm it loads and
queries successfully -- same thing you'd check locally at
`http://localhost:5000`, just over the public hostnames.

## Keeping it updated later

**Automatically**: `nightly-harvest.{sh,service,timer}` run the full harvest
-- pull latest pipeline code, re-run all eight pipelines, re-index, restart
QLever -- as the `silk` user, nightly at 3am (`+/- 5min RandomizedDelaySec`).
Installed once via:

```bash
cp deploy/nightly-harvest.* /etc/systemd/system/   # service + timer only; .sh stays under ~/triplestore/deploy
cp deploy/nightly-harvest.sh ~/triplestore/deploy/
systemctl daemon-reload
systemctl enable --now nightly-harvest.timer
```

Each pipeline needs its own sibling checkout under `~/pipelines/<repo>`
with its own `.venv` already set up (same as a local dev checkout), plus
-- for `orcid-etl` and `identity-etl` -- their personally-identifying
`--data-dir` populated (`~/orcid-etl-data/colleagues.yaml`,
`~/identity-etl-data/identities.yaml`) since those never live inside the
repo itself. Logs append to `~/triplestore/nightly-harvest.log`.

**Manually**, for an immediate push without waiting for 3am: when any
pipeline produces new output, rebuild the index locally as usual (`qlever
index`), then repeat step 2's rsync and run `qlever stop && qlever start`
on the VPS (no `index` step needed there -- you're shipping an
already-built index, not rebuilding on the VPS).
