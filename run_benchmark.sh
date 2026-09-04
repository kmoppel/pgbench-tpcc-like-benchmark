#!/bin/bash

if [ ! -d pgbench-tpcc-like ] ; then
  echo "Expecting pgbench-tpcc-like checked out!"
  echo "Run: git clone https://github.com/kmoppel/pgbench-tpcc-like"
  exit 1
fi

set -e

PGHOST_TESTDB=127.0.0.1
PGPORT_TESTDB=6666
PGDATABASE_TESTDB=postgres
PGUSER_TESTDB=$USER
PGPASSWORD_TESTDB=postgres
CONNSTR_TESTDB="postgresql://${PGUSER_TESTDB}:${PGPASSWORD_TESTDB}@${PGHOST_TESTDB}:${PGPORT_TESTDB}/${PGDATABASE_TESTDB}?sslmode=disable"  # instances will be initialized
CONNSTR_RESULTSDB="postgresql://postgres@localhost:5432/resultsdb?sslmode=disable" # assumed existing and >= v13 for storing pg_stat_statement results from test instances
EXEC_ENV=local

# paths to Postgres installations to include into testing
declare -a BINDIRS
declare -a PGVER_MAJORS

BINDIRS+=("/usr/lib/postgresql/18/bin")
PGVER_MAJORS+=("18")
BINDIRS+=("/usr/lib/postgresql/19/bin")
#BINDIRS+=("/usr/local/pgsql_19beta3/bin")
PGVER_MAJORS+=("19")


PGBENCH=/usr/lib/postgresql/18/bin/pgbench


REMOVE_INSTANCES=1  # if set then 'rm -rf' each test instance DATADIR at end of test run (in case low on disk)
DATADIR=$HOME/tpcc_like_testset
mkdir -p $DATADIR
LOGDIR=$PWD/logs
mkdir -p $LOGDIR

TPCC_WAREHOUSES="80 200" # 1 WH ~ 110MB of data and indexes
                           # In-mem vs light disk access (assuming 16GB RAM)
                           # NB! Should be divisible by 2
ACTIVE_WHS=0.5 # 0.1..1.0, % of active dataset to be worked on

PGBENCH_TRANSACTIONS=100000  # 100k


PGBENCH_PROTOCOL="simple"
PARTITIONS=0

DISABLE_AUTOVACUUM=1 # To reduce randomness. Should combine with a bit of fillfactor in init flags to reduce write tx degradation for long test runs
SLEEP_BETWEEN_RUNS=300 # To ease monitoring + possibly offset CPU "turbo" mode effects, favouring 1st tests


CPUS=`nproc`
PGBENCH_CLIENTS=$((CPUS/2))
if [ "$PGBENCH_CLIENTS" -eq 0 ]; then
  PGBENCH_CLIENTS=1
fi
PGBENCH_JOBS=$((CPUS/8))  # Should increase for heavy CPU count test nodes
if [ "$PGBENCH_JOBS" -eq 0 ]; then
  PGBENCH_JOBS=1
fi
QUERY_MODE=tpcc-like


echo "PGBENCH_CLIENTS $PGBENCH_CLIENTS"
echo "PGBENCH_JOBS $PGBENCH_JOBS"
echo "PGBENCH_TRANSACTIONS $PGBENCH_TRANSACTIONS"
echo "TPCC_WAREHOUSES $TPCC_WAREHOUSES"


SQL_PGSS_SETUP="CREATE EXTENSION IF NOT EXISTS pg_stat_statements SCHEMA public;"
SQL_PGSS_RESULTSDB_SETUP="CREATE TABLE IF NOT EXISTS public.pgss_results AS SELECT ''::text AS exec_env, now() AS test_start_time, ''::text AS hostname, now() AS created_on, 0::numeric AS pgver, 0 as pgminor, 0 AS scale, 0 as partitions, 0 AS transactions, 0 AS clients, ''::text AS protocol, ''::text AS query_mode, mean_exec_time, stddev_exec_time, calls, rows, shared_blks_hit, shared_blks_read, shared_blk_read_time, shared_blk_write_time, query FROM public.pg_stat_statements WHERE false;"
SQL_PGSS_RESET="SELECT public.pg_stat_statements_reset();"
SQL_PGSTATS_RESET="SELECT pg_stat_reset();"
SQL_DISABLE_AUTOVACUUM="ALTER SYSTEM SET autovacuum TO off;"
SQL_ENABLE_AUTOVACUUM="ALTER SYSTEM SET autovacuum TO on;"

function exec_sql() {
    psql "$CONNSTR_TESTDB" -Xqc "$1"
}

function exec_sql_resultsdb() {
    psql "$CONNSTR_RESULTSDB" -Xqc "$1"
}


HOSTNAME=`hostname`
START_TIME=`date +%s`
START_TIME_PG=`psql "$CONNSTR_RESULTSDB" -qAXtc "select now();"`

echo "Ensuring pg_stat_statements extension on result server and public.pgss_results table ..."
exec_sql_resultsdb "$SQL_PGSS_SETUP"
exec_sql_resultsdb "$SQL_PGSS_RESULTSDB_SETUP"


### Loop over all postgres versions, creating instances one by one, applying some PG config settings and starting

i=0
for BINDIR in "${BINDIRS[@]}" ; do
PGVER_MAJOR=${PGVER_MAJORS[i]}

echo -e "\n\n\n################ Initializing PGVER $PGVER_MAJOR ################\n"

if [ -e ${DATADIR}/pg${PGVER_MAJOR} ]; then
  echo "Cleaning possible prev state ..."
  set +e
  $BINDIR/pg_ctl --wait --log ${LOGDIR}/postgresql_${PGVER_MAJOR}.log -D ${DATADIR}/pg${PGVER_MAJOR} stop
  sleep 1
  set -e
  rm -rf ${DATADIR}/pg${PGVER_MAJOR}
fi

echo "$BINDIR/initdb --auth=trust --data-checksums --username=$PGUSER_TESTDB $DATADIR/pg${PGVER_MAJOR}  >/dev/null"
$BINDIR/initdb --auth=trust --data-checksums --username=$PGUSER_TESTDB ${DATADIR}/pg${PGVER_MAJOR}  >/dev/null

cat postgresql.tune.conf >> ${DATADIR}/pg${PGVER_MAJOR}/postgresql.conf
echo "port=${PGPORT_TESTDB}" >> ${DATADIR}/pg${PGVER_MAJOR}/postgresql.conf

echo "$BINDIR/pg_ctl --wait --log ${LOGDIR}/postgresql_${PGVER_MAJOR}.log -D ${DATADIR}/pg${PGVER_MAJOR} start"
$BINDIR/pg_ctl --wait --log ${LOGDIR}/postgresql_${PGVER_MAJOR}.log -D ${DATADIR}/pg${PGVER_MAJOR} start

if [ "$PGDATABASE_TESTDB" != "postgres" ]; then
  $BINDIR/createdb "$PGDATABASE_TESTDB"
fi

SERVER_VERSION_NUM=`psql "$CONNSTR_TESTDB" -qAXtc "show server_version_num"`
echo "Connection OK, SERVER_VERSION_NUM $SERVER_VERSION_NUM"

echo "Ensuring pg_stat_statements extension on test instance ..."
exec_sql "$SQL_PGSS_SETUP"



if [ "$DISABLE_AUTOVACUUM" -gt 0 ]; then
  echo -e "\nWARNING Disabling Autovacuum on instance level ..."
  psql -X "$CONNSTR_TESTDB" -c "$SQL_DISABLE_AUTOVACUUM" -c "SELECT pg_reload_conf()"
else
  psql -X "$CONNSTR_TESTDB" -c "$SQL_ENABLE_AUTOVACUUM" -c "SELECT pg_reload_conf()"
fi


echo "Starting the test loop ..."
date ; date +%s


for SCALE in $TPCC_WAREHOUSES ; do

echo -e "\n*** INIT DATA TPCC_WAREHOUSES SCALE $SCALE ***\n"

echo "Creating test data ..."
date ; date +%s

psql "$CONNSTR_TESTDB" -X -f pgbench-tpcc-like/00_schema.sql
INIT_TX=$((SCALE/PGBENCH_CLIENTS))
if [ $INIT_TX -eq 0 ]; then
  INIT_TX=1
fi

T1=$(date +%s)
$PGBENCH "$CONNSTR_TESTDB" -n -f pgbench-tpcc-like/01_init_data.pgbench -c $PGBENCH_CLIENTS -t $INIT_TX -P 60
psql "$CONNSTR_TESTDB" -Xqc "$1"

echo "Init data finished"
date ; date +%s
T2=$(date +%s)
INIT_DUR=$((T2-T1))
DB_SIZE=$(psql "$CONNSTR_TESTDB" -XAtqc "select pg_size_pretty(pg_database_size(current_database()))")
DB_SIZE_MBYTES=$(psql "$CONNSTR_TESTDB" -XAtqc "select (pg_database_size(current_database()) / 1e6)::int")
MBS=$((DB_SIZE_MBYTES/INIT_DUR))
echo "SCALE $SCALE resulted in $DB_SIZE , in $INIT_DUR seconds"

echo "vacuum analyze ..."
exec_sql "vacuum analyze"

echo -e "\nTable sizes"
exec_sql "\dt+"


echo -e "\n*** Testing query model: $QUERY_MODE with protocol $PGBENCH_PROTOCOL ***\n"

echo "Reseting pg_stat_statements..."
exec_sql "$SQL_PGSS_RESET" >/dev/null

echo "Running the timed query test ..."

pushd pgbench-tpcc-like/

# $PGBENCH -n --random-seed 666 -M $PGBENCH_PROTOCOL -j $PGBENCH_JOBS -c $PGBENCH_CLIENTS -t $PGBENCH_TRANSACTIONS "$CONNSTR_TESTDB" &> /tmp/pgbench_testset_pg_${SERVER_VERSION_NUM}_q_${QUERY_MODE}_c_${PGBENCH_CLIENTS}_s_${SCALE}_p_${PARTITIONS}.log
echo "pgbench -n --random-seed 666 -M $PGBENCH_PROTOCOL -j $PGBENCH_JOBS -c $PGBENCH_CLIENTS -t $PGBENCH_TRANSACTIONS -P 300 -D ACTIVE_WHS=$ACTIVE_WHS \
  -f new_order.pgbench@45 -f payment_transaction.pgbench@43 -f order_status.pgbench@4 \
  -f delivery_transaction.pgbench@4 -f stock_check.pgbench@4 "$CONNSTR_TESTDB" &> ${LOGDIR}/pgbench_testset_pg_${SERVER_VERSION_NUM}_q_${QUERY_MODE}_c_${PGBENCH_CLIENTS}_s_${SCALE}_p_${PARTITIONS}.log"
pgbench -n --random-seed 666 -M $PGBENCH_PROTOCOL -j $PGBENCH_JOBS -c $PGBENCH_CLIENTS -t $PGBENCH_TRANSACTIONS -P 300 -D ACTIVE_WHS=$ACTIVE_WHS \
  -f new_order.pgbench@45 -f payment_transaction.pgbench@43 -f order_status.pgbench@4 \
  -f delivery_transaction.pgbench@4 -f stock_check.pgbench@4 "$CONNSTR_TESTDB" &> ${LOGDIR}/pgbench_testset_pg_${SERVER_VERSION_NUM}_q_${QUERY_MODE}_c_${PGBENCH_CLIENTS}_s_${SCALE}_p_${PARTITIONS}.log

popd

echo "Storing pg_stat_statements results into resultsdb public.pgss_results ..."

# Assuming PG v13+
echo "psql \"$CONNSTR_TESTDB\" -qXc \"copy (select '${EXEC_ENV}', '${START_TIME_PG}', '${HOSTNAME}', now(), ${PGVER_MAJOR}, ${SERVER_VERSION_NUM}, ${SCALE}, ${PARTITIONS}, ${PGBENCH_TRANSACTIONS}, ${PGBENCH_CLIENTS}, '${PROTOCOL}', '${QUERY_MODE}', mean_exec_time, stddev_exec_time, calls, rows, shared_blks_hit, shared_blks_read, shared_blk_read_time, shared_blk_write_time, query from public.pg_stat_statements where calls > 10 and query ~* '(INSERT|UPDATE|SELECT|DELETE).*(customer|district|history|item|new_order|oorder|order_line|stock|warehouse)') to stdout\" | psql \"$CONNSTR_RESULTSDB\" -qXc \"copy public.pgss_results from stdin\""
psql "$CONNSTR_TESTDB" -qXc "copy (select '${EXEC_ENV}', '${START_TIME_PG}', '${HOSTNAME}', now(), ${PGVER_MAJOR}, ${SERVER_VERSION_NUM}, ${SCALE}, ${PARTITIONS}, ${PGBENCH_TRANSACTIONS}, ${PGBENCH_CLIENTS}, '${PROTOCOL}', '${QUERY_MODE}', mean_exec_time, stddev_exec_time, calls, rows, shared_blks_hit, shared_blks_read, shared_blk_read_time, shared_blk_write_time, query from public.pg_stat_statements where calls > 10 and query ~* '(INSERT|UPDATE|SELECT|DELETE).*(customer|district|history|item|new_order|oorder|order_line|stock|warehouse)') to stdout" | psql "$CONNSTR_RESULTSDB" -qXc "copy public.pgss_results from stdin"

echo "Sleeping $SLEEP_BETWEEN_RUNS s before next test start ..."
sleep $SLEEP_BETWEEN_RUNS

echo "Done with SCALE $SCALE"
done # SCALE

echo "Storing DB and table stats to ${LOGDIR}/after_run_summary_v${PGVER_MAJOR}_scale_${SCALE}_q_${QUERY_MODE}.log ..."
psql "$CONNSTR_TESTDB" -Xe -f after_run_get_summary.sql &> "${LOGDIR}/after_run_summary_v${PGVER_MAJOR}_scale_${SCALE}_q_${QUERY_MODE}.log"

echo "$BINDIR/pg_ctl --wait -t 300 -D ${DATADIR}/pg${PGVER_MAJOR} stop"
$BINDIR/pg_ctl --wait -t 300 -D ${DATADIR}/pg${PGVER_MAJOR} stop

i=$((i+1))

if [ "$REMOVE_INSTANCES" -gt 0 ]; then
  if [ $i -lt ${#BINDIRS[@]} ]; then # Leave the last one for possible debug
    echo "Removing instance $PGVER_MAJOR ..."
    rm -rf ${DATADIR}/pg${PGVER_MAJOR}
  fi
fi

done # BINDIR

date ; date +%s
END_TIME=`date +%s`
echo -e "\nDONE in $((END_TIME-START_TIME)) s"
