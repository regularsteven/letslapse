<?php
// Read-only: the usage ledger and the account's tables for the sync-cost
// bench. Run through `php artisan tinker --execute="require '…/ledger.php';"`
// in the picplace repo with BENCH_USER (username) and BENCH_SINCE (ledger id,
// exclusive) in the environment. Prints one JSON object.
use Illuminate\Support\Facades\DB;
$username = getenv('BENCH_USER') ?: 'synth';
$since = (int) (getenv('BENCH_SINCE') ?: 0);
$user = App\Models\User::where('username', $username)->first();
if ($user === null) { echo json_encode(['error' => "no user $username"])."\n"; return; }
$pids = DB::table('letslapse_projects')->where('user_id', $user->id)->select('id');
$events = DB::table('letslapse_usage_events')->where('user_id', $user->id)->where('id', '>', $since)
    ->selectRaw('event, count(*) n, coalesce(sum(bytes_in),0) bytes_in, coalesce(sum(bytes_out),0) bytes_out')
    ->groupBy('event')->get()->keyBy('event')->map(fn ($r) => ['n' => (int) $r->n, 'bytes_in' => (int) $r->bytes_in, 'bytes_out' => (int) $r->bytes_out]);
$out = [
    'user' => $username,
    'ledger_max_id' => (int) DB::table('letslapse_usage_events')->max('id'),
    'since' => $since,
    'events' => $events,
    'projects' => [
        'live' => (int) DB::table('letslapse_projects')->where('user_id', $user->id)->whereNull('deleted_at')->count(),
        'trashed' => (int) DB::table('letslapse_projects')->where('user_id', $user->id)->whereNotNull('deleted_at')->count(),
        'by_type' => DB::table('letslapse_projects')->where('user_id', $user->id)->selectRaw('type, count(*) n')->groupBy('type')->pluck('n', 'type'),
        'manifest_bytes' => (int) DB::table('letslapse_projects')->where('user_id', $user->id)->sum('manifest_bytes'),
    ],
    'assets' => DB::table('letslapse_assets')->whereIn('project_id', $pids)
        ->selectRaw('kind, status, count(*) n, coalesce(sum(bytes),0) bytes')->groupBy('kind', 'status')->get()
        ->map(fn ($r) => ['kind' => $r->kind, 'status' => $r->status, 'n' => (int) $r->n, 'bytes' => (int) $r->bytes]),
    'presences' => DB::table('letslapse_presences')->whereIn('project_id', $pids)->selectRaw('tier, count(*) n')->groupBy('tier')->pluck('n', 'tier'),
    'index' => [
        'rows' => (int) DB::table('letslapse_project_index')->where('user_id', $user->id)->count(),
        'name_null' => (int) DB::table('letslapse_project_index')->where('user_id', $user->id)->whereNull('name')->count(),
        'records_indexed' => (int) DB::table('letslapse_project_index')->where('user_id', $user->id)->whereNotNull('records_indexed_at')->count(),
    ],
    'uploads_pending' => (int) DB::table('letslapse_uploads')->whereIn('asset_id', DB::table('letslapse_assets')->whereIn('project_id', $pids)->select('id'))->count(),
];
echo "BENCH_JSON ".json_encode($out)."\n";
