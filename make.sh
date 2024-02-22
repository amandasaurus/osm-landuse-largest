#!/bin/bash
set -o errexit -o nounset

INPUT=planet-latest.osm.pbf

while getopts "i:v" OPT ; do
	case $OPT in
		v) set -v ;;
		i) INPUT=$OPTARG ;;
		*) exit 1 ;;
	esac
done
PREFIX=$(basename "$INPUT")
PREFIX=${PREFIX%%.osm.pbf}
PREFIX=${PREFIX%%-latest}


if [ ! -e "$INPUT" ] ; then
	aria2c --seed-time=0 https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf.torrent
fi

if [ "${INPUT}" -nt "${PREFIX}-landuse.osm.pbf" ] ; then
	osmium tags-filter --overwrite "${INPUT}" -o "${PREFIX}-landuse.osm.pbf" landuse
fi
osm2pgsql -O flex -S ./osm2pgsql-landuses-import.lua "${PREFIX}-landuse.osm.pbf"
psql -XAt -c "alter table landuse add column area real;"
psql -XAt -c "update landuse set area = st_area(geom::geography);"
psql -XAt -c "create index landuse__area on landuse (area);"

# only include landuses whose total is ≥ 1% of the most popular landuse
echo "Deleting uncommon landuse values"
MIN_COUNT=$(psql -XAt -c "select count(*)/100 as count from landuse group by landuse order by count desc limit 1;")
psql -XAt -c "with landuse_counts AS (select count(*), landuse from landuse group by landuse), unwanted_landuse AS ( select landuse from landuse_counts where count <= ${MIN_COUNT}) delete from landuse using unwanted_landuse where unwanted_landuse.landuse = landuse.landuse;"
echo "There are $(psql -XAt -c "select count(distinct landuse) from landuse") distinct landuse values"
psql -o "landuse_area_p99.csv" -XAt -c "copy (select landuse as landuse_value, round(percentile_cont(0.01) within group (order by area desc)::numeric, 1) as area_m2_p99 from landuse group by landuse_value order by landuse_value ) to stdout with (format csv, header on)"

# clean up and remove small objects
# TODO Could I do this in one query? 🤔
cat landuse_area_p99.csv | sed 1d | while IFS=, read -r LANDUSE_VALUE MIN_AREA ; do
	echo "Removing small $LANDUSE_VALUE values (ie ≤ $MIN_AREA m²)"
	psql -XAt -E -c "delete from landuse where landuse = '$LANDUSE_VALUE' and area < $MIN_AREA"
done

cat landuse_area_p99.csv | sed 1d | while IFS=, read -r LANDUSE_VALUE MIN_AREA ; do
	echo "Dumping for $LANDUSE_VALUE (which must be ≥ $MIN_AREA)"
	psql -XAt -o "landuse_${LANDUSE_VALUE}_largest0.01.csv" -c "copy (
	select row_number() over (order by area desc) as rank, lower(osm_type)||osm_id as osm_id, 'https://www.openstreetmap.org/'||case osm_type when 'R' then 'relation' when 'W' then 'way' end||'/'||osm_id as osm_url, area as area_m2, area*1e-06 as area_km2, st_astext(geom) as geometry from landuse where landuse =  '${LANDUSE_VALUE}' order by area desc
		) to stdout with (format csv, header on);"
	ogr2ogr -f GeoJSON "landuse_${LANDUSE_VALUE}_largest0.01.geojson" "landuse_${LANDUSE_VALUE}_largest0.01.csv"  -oo KEEP_GEOM_COLUMNS=no -oo GEOM_POSSIBLE_NAMES=geometry -oo HEADERS=yes
	bzip2 -f "landuse_${LANDUSE_VALUE}_largest0.01.csv"
	bzip2 -f "landuse_${LANDUSE_VALUE}_largest0.01.geojson"
done
