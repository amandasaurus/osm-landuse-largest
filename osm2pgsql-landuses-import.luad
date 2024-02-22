local tables = {}

tables.landuse = osm2pgsql.define_table({
	name = 'landuse',
	ids = { type = 'any', id_column = 'osm_id', type_column = 'osm_type' },
	columns = {
		{ column = 'landuse', type = 'text' },
		{ column = 'geometry', type = 'multipolygon', projection = 4326 },
	},
	{ indexes = { { column = "landuse", method = "btree" }, } }
})

function insert_object(object) 
	local geom = object:as_multipolygon();
	tables.landuse:insert({
		landuse = object.tags.landuse,
		geometry = geom,
	});
end

function osm2pgsql.process_way(object)
	if object.tags.landuse and object.is_closed then
		insert_object(object);
	end
end

function osm2pgsql.process_relation(object)
	if object.tags.landuse then
		insert_object(object);
	end
end
