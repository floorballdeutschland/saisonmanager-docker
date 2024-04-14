# saisonmanager-docker


## clonen dieses Repos
Das Repo sollte mit folgenden Bereich geklont werden:

```
git clone --recurse-submodules git@github.com:floorballdeutschland/saisonmanager-docker.git

```

Der Rails Code ist dabei als submodule eingebunden und kann direkt genutzt werden, ohne das er in einem zweiten verzeichnis erneut ausgecheckt werden muss.

Ein git submodule ist dabei quasi ein Repo innerhalb des dieses Repos. Es ist komplett unabhängig von diesem git-tree, commits dort wandern also ins entsprechende Repo.


## nginx initialisieren


```
openssl dhparam -out nginx/diffie-hellman-params/dhparams.pem 2048

```

Wir stellen für die Saisonmanager-Entwickler eine eigene Domain zur verfügung. Für saisonmanager.dev sind keinerlei DNS-Einträge (A/AAAA) hinterlegt. Um diese Einträge zu nutzen muss auf dem Entwicklungsrechner ein Eintrag in der Host-Datei erfolgen.

Für Linux/mac ist das /etc/hosts

```
# die IP-Adresse kann hier eingefach lokal gesetzt werden, üblicherweise
# funktioniert eine lokale Adresse gut 127.0.0.1
127.0.0.1 saisonmanager.dev

```

Für berechtigte Entwickler liegt auf dem Server das Zertifikat zum Abruf:

```
scp saisonmanager.de:/home/devs/cert/{cert.pem,chain.pem,fullchain.pem,privkey.pem} nginx/cert/

```