#!/bin/bash
set -e

# psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
#     CREATE DATABASE saisonmanager;
# EOSQL

psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER rbu;
    CREATE USER mgu;
    CREATE USER pri;
    CREATE ROLE pg;
    CREATE ROLE postgres;
    GRANT LOGIN ON DATABASE saisonmanager TO pg;
    GRANT ALL PRIVILEGES ON DATABASE saisonmanager TO pg;
EOSQL

psql --username "$POSTGRES_USER" $POSTGRES_DB < /db-dumps/import.sql

# hier werden die User deaktiviert, das solltet ihr in der Regel für eure Entwicklungsumgebung deaktivieren.
#  für das Archiv aber total sinnvoll
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname $POSTGRES_DB <<-EOSQL
    UPDATE "users" SET
        "hash_id" = '',
        "_rev" = '',
        "active" = '0',
        "alternate_password" = '',
        "alternate_password_expiration" = NULL,
        "created_by" = NULL,
        "created_by_hash" = NULL,
        "club_id" = NULL,
        "description" = '',
        "email" = 'NOLOGINONARCHIVE@floorball.de',
        "password" = '1SYiHviKMpoXe9nYDcQ6NK4JO0E6OO4NaDvQCUwsPJJbbfhwnOC3idYULhLMgsAdAMic7trEGgJ7TdJLOgiJqa2szLf4OHARMp8J1yjakwW0UoSRgjwfa8TTFZrzTibTHzdNntEf8vftsnbmHWxhOWF0WOCkipEvifohNfHRjNV7QhVceMX1qSphoO4gDJjKFAZnV5txpLTngS6nYBDwDeLfhzjLKizIeNpPZ4LcmUrEfzex1Ecr7INDxkZZBlVAlf45oJhbyBU2YycDK7Wu7knxlAgIhCxIL6aMCVwGsrNfbJSlOPMhRxxm2NEVrdixdkkS95Z9wieiDZSFqA4zsqUt665L1l6rIOlNZEyqKCvbyMk4b9foeVwOrsDdxmqzjEkk36TgwMasneoSHQWVSAWMSr7er0ssEb0yGaa8BSvUyaH1xhRYkpCAcE9ChxAtxpHNiOPL9i12C4ccUzyACrcNifjYCGT6cuW9IZn0Tlp2cWYFspBVSJDLhwhOv2hqXK0K2n7PgKGTqvRn8RoxyuHDRsa6rtvoF1GQQB6iNLvfnFVat7Lt1Q7QWS5RxhTokcY2RNlQpdVhuSFTfqBq4k6TjzuuJuE9477tVoWZU742w7rtYDSobnJhsc7MVjnX8a1XuCDKpvfTPWnqm2oCMEGsbmFS42oi0C3ntehu3Z0yUKXwheU6YihgKP7X2Wwl6KaAy2hXonWbASw7Rni1zV6nucHHopoMoOc4zEZoeDNSWuUMzp6jORUFf0E7iSXqq6T7IZyjuaJLZM3B9qPFXdijF4zkHxvYJQoEynMtMMjbAuvOTSOBz5CzFmrJ8jk7qNRrZw3iYs4vcO6AMcBlmbc5qEcy7Su6VpCvjcTOazhK7IEwxCOHjMFyuf0Wihcu6mQzTH6oobec6wc1sbGryocedsFsh6ECmVnc77bpdHQeSewXcVgY3P6gVGBVNmvRQbflW4a6YhXXb7kLXsNUHI1vI20blkLyQepCten6s7a2GHm958GbX5vv6it67jDlqrYFFwZAhTHFDPrdnUW0II9vGdocmQf3QC4TVcRiUVGxKwWmzDFDfOSzGS74hWNypQPdZ4nofXIpZIj0PcvUnkv1djqKruaOYOjXA011zdIIj1qdPsAvM3zm49USTbRiAEee2iTpULUp4uFc95YEmTANGvq9GPMyq8rZRCO27AYT1WH5oHFfAaOEhWRulXsGXyF6WnO4hvvxzjqKnatMR9JTqEkJH5jUuzkgZ7pJu0HOEXKwggdKJqq5OE9CQyGHYl4pc0Y2TEiyFDmIxc0zjGgFfICxFkJjHhNpOVW4imEPLJKI0ix2gwoTxQS0V8UOnZ3Rp7dmQUHRPCFCehnqvAWA0ysVNGw2iZGnOzYRLRNPJJ7rzWOBdvDriPq9KJElBjuhT2nNIkSq5LkfiBPXU8ecpuF3rslXMe14RErOg7bOzzBr4km0Xx1rsxagl5HSPIO5PnfB7t3rodgJsp1NSw6JC14AFVxIt403fCHzfewjCrMhwqGtHHJZDhspxVxhRQUxu7M8Bo31hI5J8tnRrzVd9CyxoMqst9zMUnwDmvdm6JSWb8ycbIph5sGOZ8pwha0oNp6wGnU7luH2Q2oU2AgvWV9sSIqMTAuq2OxSqW37G0dPDZqGxxI1I28yEfGEZ0wSzoY8tBJR805rdQ73KbXQvMwthvLuawKhivF0j0kdI19FtIW1eAXx4bF08TjkY9crwxpU9vQ4jez81sNFnWteu7dCzmIpriTBK2OIjZxsoJFosoaDhFpZwlQdqtwQedhXKOZS5fhuIfcKa7mTGoUDE61UpwBimgvkT6nDxA2QttEUJZSbK3QoVbcdw1YMNnqvZucQFlKrtHXdGpMxfAWGcLUa6KeDea6sQeCmNiJRT2zU4YMYuZEGmzyU31CcUXLUqblbmojRvwRGUxt8zrWLcINDcrj0CCkzEr7NPrgTcVTYQWXetwzVCr9x',
        "permissions" = '[]',
        "privacy_approved" = '0',
        "teams" = '{}',
        "updated_at" = NULL,
        "updated_by" = NULL,
        "updated_by_hash" = NULL,
        "user_name" = 'NOLOGINFROMARCHIVE'
        WHERE id NOT IN (1445, 436, 622, 689, 1006, 1132, 1155, 1691, 1396, 1369, 829, 619, 113);
EOSQL
