# Apache Superset
rebuild de la image de apache/superset:1.5.0 con el geojson de AR y otras modificaciones para el uso del MDSNación.

# Uso
1) iniciar submodule de superset `git submodule update --init`
2) modificar `superset_config.py` a gusto
3) para iniciarlo `docker-compose up -d`
4) apuntar reverse proxy a 127.0.0.1:8088

# Dev
Para hacer cambios sobre la codebase de superset se usa el compose que viene.
1) iniciar submodule de superset `git submodule update --init`
2) `cd superset` y usar el Dockerfile de ahí. Seguir las [instrucciones de la documentación](https://superset.apache.org/docs/installation/installing-superset-using-docker-compose/).
