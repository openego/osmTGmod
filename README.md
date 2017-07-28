## About osmTGmod
osmTGmod is a load-flow model of the German transmission-gird, based on the free geo-database OpenStreetMap (OSM). The model, respectively the abstraction process employs a PostgreSQL-database extended by PostGIS. The key part of the abstraction process is implemented in SQL and ProstgreSQL's procedural language pl/pgSQL. The abstraction and all additional modules are controlled by a Python-environment.

Sorry for the documentation being partly German.

## Documentation
For a detailed description/documentation, please refer to documentation.pdf

## Run an abstraction
1. Use the python file ego_otg.py for the definition of covered voltage levels
2. Set database connection parameters and your preferences regarding the connection of transfer-busses or subgrids in example.cfg
3. Choose a fitting name for your config file
4. run the abstraction via terminal by: python ego_otg.py YOUR_CONFIG.cfg

## transfer busses
Make sure current transfer-busses are taken from oedb. Use the following command to extract a csv:

SELECT DISTINCT ON (osm_id) * FROM (
SELECT * FROM model_draft.ego_grid_ehv_substation
UNION
SELECT subst_id, lon, lat, point, polygon, voltage, power_type, substation, osm_id, osm_www, frequency, subst_name, ref, operator, dbahn, status, otg_id FROM model_draft.ego_grid_hvmv_substation
--GROUP BY osm_id
ORDER BY osm_id
) as foo;
