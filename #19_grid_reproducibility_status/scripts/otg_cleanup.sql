-- Clear osmTGmod's transient working tables.
--
-- power_script.sql drops the tables it owns at the top, but only some of
-- them: the split_table_* set, table_order, branch_data_topo and friends are
-- created mid-script and dropped near the end. A run that dies partway
-- therefore leaves them behind, and the next run fails with
--   ERROR: relation "split_table_1" already exists
-- Running this before each trial makes the harness idempotent.
--
-- Deliberately NOT dropped, because they are the *input* to the abstraction
-- and are built at import time by otg_create_power_tables():
--   power_ways, power_relations, power_relation_members,
--   edit_power_relations, power_way_nodes,
--   transfer_busses (written by egon-data), nuts_poly, abstr_values

DROP TABLE IF EXISTS split_table_1  CASCADE;
DROP TABLE IF EXISTS split_table_2  CASCADE;
DROP TABLE IF EXISTS split_table_3  CASCADE;
DROP TABLE IF EXISTS split_table_4  CASCADE;
DROP TABLE IF EXISTS split_table_5  CASCADE;
DROP TABLE IF EXISTS split_table_6  CASCADE;
DROP TABLE IF EXISTS split_table_7  CASCADE;
DROP TABLE IF EXISTS split_table_8  CASCADE;
DROP TABLE IF EXISTS split_table_9  CASCADE;
DROP TABLE IF EXISTS split_table_10 CASCADE;
DROP TABLE IF EXISTS table_order CASCADE;

DROP TABLE IF EXISTS branch_data_topo CASCADE;
DROP TABLE IF EXISTS branch_data_topo_vertices_pgr CASCADE;
DROP TABLE IF EXISTS power_line_sep_vertices_pgr CASCADE;

DROP TABLE IF EXISTS branch_data_new_busses CASCADE;
DROP TABLE IF EXISTS bus_data_combine_busses CASCADE;
DROP TABLE IF EXISTS buffers_matching_busses CASCADE;
DROP TABLE IF EXISTS subgrids_connect CASCADE;
DROP TABLE IF EXISTS all_neighbours CASCADE;

-- created and dropped inside otg_graph_dfs
DROP TABLE IF EXISTS this CASCADE;
DROP TABLE IF EXISTS v_next CASCADE;

-- rebuilt from transfer_busses by otg_transfer_busses
DROP TABLE IF EXISTS transfer_busses_connect CASCADE;
DROP TABLE IF EXISTS transfer_busses_connect_all CASCADE;
