/*
electrical_properties -
script to assign electrical parameters to all assets in osmTGmod.
__copyright__ 	= "DLR Institute of Networked Energy Systems"
__license__ 	= "GNU Affero General Public License Version 3 (AGPL-3.0)"
__url__ 	= "https://github.com/openego/osmTGmod/blob/master/LICENSE"
__author__ 	= "lukasol"
Contains: Proportions of the code by "Wuppertal Institut" (2015)                                          
                                                                             
--  Licensed under the Apache License, Version 2.0 (the "License")               
--  you may not use this file except in compliance with the License.              
--  You may obtain a copy of the License at                                       
--                                                                                
--      http://www.apache.org/licenses/LICENSE-2.0                                
--                                                                                
--  Unless required by applicable law or agreed to in writing, software           
--  distributed under the License is distributed on an "AS IS" BASIS,             
--  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.      
--  See the License for the specific language governing permissions and           
--  limitations under the License. 
*/

SET SCHEMA 'public';
SET CLIENT_ENCODING TO UTF8;
SET STANDARD_CONFORMING_STRINGS TO ON;

-- AC-LINES

DROP TABLE IF EXISTS branch_specifications;	
CREATE TABLE branch_specifications (	spec_id serial NOT NULL PRIMARY KEY,
					voltage_kV INT, 
					power TEXT, 
					AL_mm2 TEXT, -- Aluminium Steel 
					Stherm_MVA INT, -- Thermal power (in this case possible permanent load)
					Snat_MVA INT, -- natural load
					R_Ohm_per_km REAL, -- ohmic resistance 
					L_mH_per_km REAL, -- inductive resistance 
					G_nS_per_km REAL, -- 
					C_nF_per_km REAL, -- capacitive resistance
					Zw_Ohm INT); -- characteristic impedance 

-- The following data was taken from "Freileitung vs. Kabel" (http://www.ets.uni-duisburg-essen.de/download/public/Freileitung_Kabel.pdf).
-- In theory, the values must be calculated for every single line since the results are strongly dependend on the wire distance etc.
-- The parameters refer to a standard 3-cable system
-- Stherm and Snat refer to the full system (3 cables)
-- this convention is also applied by matpower					

INSERT INTO branch_specifications 
	VALUES (DEFAULT, 110, 'line', '2*265/35', 260, 34, 0.109, 1.2, 40, 9.5, 355);
INSERT INTO branch_specifications 
	VALUES (DEFAULT, 110, 'cable', '1400', 280, 347, 0.0177, 0.3, 78, 250, 35);
INSERT INTO branch_specifications 
	VALUES (DEFAULT, 220, 'line', '2*265/35', 520, 136, 0.109, 1.0, 30, 11, 302);
INSERT INTO branch_specifications 
	VALUES (DEFAULT, 220, 'cable', '1400', 550, 1250, 0.0176, 0.3, 67, 210, 39);
INSERT INTO branch_specifications 
	VALUES (DEFAULT, 380, 'line', '4*265/35', 1790, 600, 0.028, 0.8, 15, 14, 240);
INSERT INTO branch_specifications 
	VALUES (DEFAULT, 380, 'cable', '1400', 925, 3290, 0.0175, 0.3, 56, 180, 44);


-- DC-LINES

DROP TABLE IF EXISTS dcline_specifications;	
CREATE TABLE dcline_specifications (
			spec_id serial NOT NULL PRIMARY KEY,
			power TEXT,
			r_ohm_per_km REAL,
			I_A_therm REAL,	
			leitertyp TEXT);
			
-- The following data was taken from "Szenarien für eine langfristige Netzentwicklung" (https://www.bmwi.de/Redaktion/DE/Publikationen/Studien/szenarien-fuer-eine-langfristige-netzentwicklung.pdf?__blob=publicationFile&v=5)
-- The source distincts between CSC cable, overhead line and VSC. The relevant parameters for the grid model are, however, equal.
-- The maximum thermal transmission power is calculated via the thermal limit current.
-- For HVDC lines it is important to note how the voltage is marked. For two-way (bipolar) transmission, one normally assigns +- (the voltage is in this case doubled)


INSERT INTO dcline_specifications
	VALUES (DEFAULT, 'line', 0.0159, 3840, '4er Buendel 490-Al1/64-ST1A');
INSERT INTO dcline_specifications
	VALUES (DEFAULT, 'cable', 0.0132, 1875, '1x2500 Al Mass impregnated');



-- TRANSFORMER

DROP TABLE IF EXISTS transformer_specifications;	
CREATE TABLE transformer_specifications (	
					spec_id serial NOT NULL PRIMARY KEY,
					S_MVA INT, -- apparent power
					U_OS REAL, -- upper voltage (Volt)
					U_US REAL, -- under voltage (Volt)
					u_kr REAL); -- relative short-circuit voltage (%)
--Transformer data from:					
-- Springer: Elektrische Kraftwerke und Netze p. 228					

INSERT INTO transformer_specifications 
	VALUES (DEFAULT, 1000, 380000, 220000, 13.5); -- Springer: Elektrische Kraftwerke und Netze p. 228/219
INSERT INTO transformer_specifications 
	VALUES (DEFAULT, 300, 380000, 110000, 14);
INSERT INTO transformer_specifications 
	VALUES (DEFAULT, 200, 220000, 110000, 12);
