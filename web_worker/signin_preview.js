// LOCAL-ONLY module. Import from the existing Worker only after separate
// backend + binding/publication review. No credentials belong in Flutter.
// Requires server bindings SIGNIN_PREVIEW_SUPABASE_URL,
// SIGNIN_PREVIEW_SUPABASE_SERVICE_ROLE and SIGNIN_PREVIEW_RATE_LIMIT.
const PREFIX = '/api/signin-preview/';
const MAX_BYTES = 1024 * 1024;
const TTL_MS = 30_000;
const MAX_CACHE_ENTRIES = 128;
const GAME_FIELDS = new Set(['event_id','id','round_id','round_slug','tour_id',
  'tour_slug','name','fen','last_move','think_time','status','lichess_id',
  'date_start','time_start','board_nr','last_move_time','game_day',
  'last_clock_white','last_clock_black','eco','opening_name','time_control',
  'avg_elo','round_starts_at','round_name','tour_name','event_name','time_control_text']);
const PLAYER_FIELDS = new Set(['name','title','rating','fideId','fed','clock','team','customPoints']);
const EVENT_FIELDS = new Set(['id','created_at','name','max_avg_elo','date_start',
  'date_end','time_control','date_closest_round']);
const ID = /^[^\u0000-\u001f\u007f]{1,256}$/u; // Opaque source IDs, never normalized.
class PreviewError extends Error {
  constructor(status) { super('preview unavailable'); this.status = status; }
}
function json(data, status=200) {
  return new Response(JSON.stringify(data), {status, headers:{
    'Content-Type':'application/json; charset=utf-8',
    // Cache only in this bounded handler, never a browser/CDN authentication cache.
    'Cache-Control':'no-store', 'X-Content-Type-Options':'nosniff',
    'Content-Security-Policy':"default-src 'none'; frame-ancestors 'none'",
    'Cross-Origin-Resource-Policy':'same-origin',
    ...(status === 405 ? {Allow:'GET'} : {}),
    ...(status === 429 ? {'Retry-After':'60'} : {}),
  }});
}
function object(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
function failUnless(condition, status=502) { if (!condition) throw new PreviewError(status); }
function publicScalars(value, fields, maxLength=256) {
  failUnless(object(value));
  const out = {};
  for (const [key,item] of Object.entries(value)) {
    if (!fields.has(key)) continue;
    if (key==='id' || key.endsWith('_id')) {
      failUnless(item===null || (typeof item==='string' && ID.test(item)));
    }
    if (key.endsWith('_slug')) failUnless(item===null || (typeof item==='string' && item.length<=256));
    failUnless(item === null || ['string','number','boolean'].includes(typeof item));
    if (typeof item === 'number') failUnless(Number.isFinite(item));
    out[key] = typeof item === 'string' ? item.slice(0,maxLength) : item;
  }
  return out;
}
function game(value) {
  failUnless(object(value) && typeof value.id==='string' && ID.test(value.id));
  const out = publicScalars(value,GAME_FIELDS);
  failUnless(['id','round_id','round_slug','tour_id','tour_slug'].every(k=>typeof out[k]==='string'));
  // Games.fromJson consumes this narrow embed, not round_starts_at directly.
  out.round_schedule={starts_at:out.round_starts_at??null,name:out.round_name??null};
  failUnless(Array.isArray(value.players) && value.players.length <= 2);
  out.players = value.players.map(p=>publicScalars(p,PLAYER_FIELDS,128));
  // Keep genuinely missing positions missing; never infer/replace a FEN.
  return out;
}
function instant(value) {
  failUnless(typeof value === 'string' && value.length <= 40 &&
    /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|\+00:00)$/.test(value),400);
  const ms = Date.parse(value);
  failUnless(Number.isFinite(ms) && new Date(ms).toISOString().slice(0,19)===value.slice(0,19),400);
  const fraction=value.match(/\.(\d+)/)?.[1]||'';
  failUnless(!/[1-9]/.test(fraction.slice(3)),400);
  return ms;
}
function parts(date, timezone) {
  return Object.fromEntries(new Intl.DateTimeFormat('en-CA',{
    timeZone:timezone,year:'numeric',month:'2-digit',day:'2-digit',
    hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23',
  }).formatToParts(date).filter(p=>p.type!=='literal').map(p=>[p.type,Number(p.value)]));
}
function utcParts(p) { return Date.UTC(p.year,p.month-1,p.day,p.hour||0,p.minute||0,p.second||0); }
function zonedMidnight(local, timezone) {
  const target = local.getTime();
  // Sample both offsets around DST. Like PostgreSQL AT TIME ZONE, prefer
  // standard/later time for an ambiguous midnight; advance across a gap.
  const candidates = [...new Set([-36,0,36].map(hours=>{
    const sample = target+hours*3600000;
    return target-(utcParts(parts(new Date(sample),timezone))-sample);
  }))];
  const exact = candidates.filter(ms=>utcParts(parts(new Date(ms),timezone))===target);
  if (exact.length) return Math.max(...exact);
  const after = candidates.filter(ms=>utcParts(parts(new Date(ms),timezone))>target);
  failUnless(after.length>0,400);
  return Math.min(...after);
}
export function currentPreviewWindow(period, timezone, now = Date.now()) {
  failUnless(['today','week','month','year'].includes(period) &&
    typeof timezone === 'string' && timezone.length<=64 &&
    /^(?:UTC|[A-Za-z_]+(?:\/[A-Za-z0-9_+-]+)+)$/.test(timezone),400);
  let p;
  try { p = parts(new Date(now),timezone); } catch { throw new PreviewError(400); }
  const start = new Date(Date.UTC(p.year,p.month-1,p.day));
  if (period==='week') start.setUTCDate(start.getUTCDate()-((start.getUTCDay()+6)%7));
  if (period==='month') start.setUTCDate(1);
  if (period==='year') start.setUTCMonth(0,1);
  const end = new Date(start);
  if (period==='today') end.setUTCDate(end.getUTCDate()+1);
  if (period==='week') end.setUTCDate(end.getUTCDate()+7);
  if (period==='month') end.setUTCMonth(end.getUTCMonth()+1);
  if (period==='year') end.setUTCFullYear(end.getUTCFullYear()+1);
  return {from:new Date(zonedMidnight(start,timezone)).toISOString(),
    to:new Date(zonedMidnight(end,timezone)).toISOString()};
}
function likesParams(url, now) {
  const allowed = new Set(['period','timeZone','from','to']);
  failUnless([...url.searchParams.keys()].every(k=>allowed.has(k)) &&
    [...allowed].every(k=>url.searchParams.getAll(k).length===1),400);
  const period=url.searchParams.get('period'), timezone=url.searchParams.get('timeZone');
  const window=currentPreviewWindow(period,timezone,now);
  failUnless(instant(url.searchParams.get('from'))===Date.parse(window.from) &&
    instant(url.searchParams.get('to'))===Date.parse(window.to),400);
  return {p_period:period,p_timezone:timezone,p_from:window.from,p_to:window.to};
}
function ids(value, max) {
  failUnless(Array.isArray(value) && value.length<=max && value.every(x=>typeof x==='string' && ID.test(x)));
  return value;
}
function verifyMissingPositions(games,missing) {
  const expected=games.filter(g=>g.fen==null || (typeof g.fen==='string' && g.fen.trim()==='')).map(g=>g.id);
  failUnless(new Set(missing).size===missing.length && expected.length===missing.length && expected.every(id=>missing.includes(id)));
}
function metadataText(value, max) {
  failUnless(value === null || (typeof value === 'string' && value.length <= max &&
    !/[\u0000-\u001f\u007f]/u.test(value)));
  return value;
}
function metadataInstant(value) {
  // Compare PostgreSQL's full microsecond clock, not Date.parse's truncated ms.
  failUnless(typeof value==='string' && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|\+00:00)$/.test(value));
  const ms=Date.parse(value);
  failUnless(Number.isFinite(ms) && new Date(ms).toISOString().slice(0,19)===value.slice(0,19));
  const micros=(value.match(/\.(\d+)/)?.[1]||'').padEnd(6,'0');
  return BigInt(Math.floor(ms/1000))*1000000n+BigInt(micros);
}
function eventMetadata(value, eventIds) {
  const artwork=Object.create(null),nextRounds=Object.create(null);
  failUnless(value.artwork===undefined || object(value.artwork));
  failUnless(value.nextRounds===undefined || object(value.nextRounds));
  const images=Object.entries(value.artwork??{}), rounds=Object.entries(value.nextRounds??{});
  failUnless(images.length<=20 && rounds.length<=20);
  for(const [id,raw] of images) {
    failUnless(eventIds.has(id) && object(raw));
    const imageUrl=metadataText(raw.imageUrl??null,2048);
    if(imageUrl!==null) {
      let url; try { url=new URL(imageUrl); } catch { throw new PreviewError(502); }
      failUnless(imageUrl===imageUrl.trim() && ['http:','https:'].includes(url.protocol) &&
        url.hostname && !url.username && !url.password);
    }
    const location=metadataText(raw.location??null,256);
    const dominantFederation=metadataText(raw.dominantFederation??null,16);
    failUnless(Number.isSafeInteger(raw.playerCount) && raw.playerCount>=0);
    artwork[id]={imageUrl,location,playerCount:raw.playerCount,dominantFederation};
  }
  const capturedAt=metadataInstant(value.generatedAt);
  for(const [id,raw] of rounds) {
    failUnless(eventIds.has(id) && object(raw) && typeof raw.name==='string');
    const name=metadataText(raw.name,256);
    failUnless(metadataInstant(raw.startsAt)>capturedAt);
    nextRounds[id]={name,startsAt:raw.startsAt};
  }
  return {artwork,nextRounds};
}
function sanitize(value, route, params) {
  failUnless(object(value));
  failUnless(typeof value.generatedAt==='string' && Number.isFinite(Date.parse(value.generatedAt)));
  if (route==='likes') {
    failUnless(Array.isArray(value.rows) && value.rows.length<=12 && Array.isArray(value.games) && value.games.length<=12);
    failUnless(value.schemaVersion===1 && value.dataset==='community-likes' && value.period===params.p_period && value.timeZone===params.p_timezone &&
      Date.parse(value.from)===Date.parse(params.p_from) && Date.parse(value.to)===Date.parse(params.p_to));
    const rows=value.rows.map(r=>{
      failUnless(object(r) && typeof r.source_game_id==='string' && ID.test(r.source_game_id));
      const count=r.like_count;
      failUnless(Number.isSafeInteger(count) && count>=2);
      return {source_game_id:r.source_game_id,like_count:count};
    });
    const ranked=new Set(rows.map(r=>r.source_game_id));
    failUnless(ranked.size===rows.length);
    // Never re-sort: SQL collation is authoritative for tied counts.
    failUnless(rows.every((r,i)=>i===0 || r.like_count<=rows[i-1].like_count));
    const games=value.games.map(game);
    const missing=ids(value.unresolvedGameIds,12);
    // Internal unresolved IDs are not verified public game metadata. Keep them
    // inside the server-only RPC boundary, never in an anonymous response.
    failUnless(missing.length===0);
    failUnless(games.every(g=>ranked.has(g.id)) && missing.every(id=>ranked.has(id)));
    const resolved=new Set(games.map(g=>g.id));
    failUnless(resolved.size===games.length && new Set(missing).size===missing.length &&
      missing.every(id=>!resolved.has(id)) && resolved.size+missing.length===ranked.size);
    const positions=ids(value.missingPositionGameIds,12);
    failUnless(positions.every(id=>resolved.has(id)));
    verifyMissingPositions(games,positions);
    return {schemaVersion:1,dataset:'community-likes',period:params.p_period,timeZone:params.p_timezone,from:params.p_from,to:params.p_to,
      generatedAt:value.generatedAt,rows,games,unresolvedGameIds:missing,missingPositionGameIds:positions};
  }
  failUnless(value.schemaVersion===1 && value.dataset==='for-you' &&
    Array.isArray(value.events) && value.events.length<=20 && Array.isArray(value.games) && value.games.length<=240);
  const events=value.events.map(e=>publicScalars(e,EVENT_FIELDS));
  failUnless(events.every(e=>typeof e.id==='string' && ID.test(e.id) && typeof e.name==='string' &&
    typeof e.created_at==='string' && Number.isFinite(Date.parse(e.created_at))));
  const eventIds=new Set(events.map(e=>e.id));
  failUnless(eventIds.size===events.length);
  const games=value.games.map(game), perEvent=new Map();
  for(const g of games) {
    failUnless(eventIds.has(g.event_id));
    const count=(perEvent.get(g.event_id)||0)+1;
    failUnless(count<=12);
    perEvent.set(g.event_id,count);
  }
  failUnless(new Set(games.map(g=>g.id)).size===games.length);
  const missing=ids(value.missingPositionGameIds,240), allIds=new Set(games.map(g=>g.id));
  const strictLiveEventIds=ids(value.strictLiveEventIds,20);
  failUnless(missing.every(id=>allIds.has(id)) && strictLiveEventIds.every(id=>eventIds.has(id)));
  verifyMissingPositions(games,missing);
  return {schemaVersion:1,dataset:'for-you',generatedAt:value.generatedAt,
    events,games,strictLiveEventIds,missingPositionGameIds:missing,...eventMetadata(value,eventIds)};
}
async function limitedJson(response) {
  const length=Number(response.headers.get('Content-Length'));
  failUnless(!Number.isFinite(length) || length<=MAX_BYTES);
  failUnless((response.headers.get('Content-Type')||'').includes('application/json'));
  const reader=response.body?.getReader();
  failUnless(reader);
  let total=0; const chunks=[];
  try {
    for (;;) {
      const {done,value}=await reader.read(); if(done) break;
      total+=value.byteLength;
      if(total>MAX_BYTES) { await reader.cancel(); throw new PreviewError(502); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes=new Uint8Array(total); let offset=0;
  for(const chunk of chunks) { bytes.set(chunk,offset); offset+=chunk.byteLength; }
  try { return JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new PreviewError(502); }
}

export function createSigninPreviewHandler({fetchImpl=globalThis.fetch, now=Date.now}={}) {
  // Per-isolate memory only, finite keys, coalesced misses; no account cookies.
  const cache=new Map(), inFlight=new Map();
  return async function handleSigninPreview(request,env) {
    try {
      const url=new URL(request.url), route=url.pathname.slice(PREFIX.length);
      failUnless(url.pathname===PREFIX+'likes' || url.pathname===PREFIX+'events',404);
      failUnless(request.method==='GET',405);
      const origin=request.headers.get('Origin');
      failUnless((!origin || origin===url.origin) && request.headers.get('Sec-Fetch-Site')!=='cross-site',403);
      const params=route==='likes' ? likesParams(url,now()) : {};
      if(route==='events') failUnless(url.search==='',400);
      // Mandatory edge limiter binding (per-location, not global). No insecure local fallback.
      const ip=request.headers.get('CF-Connecting-IP');
      failUnless(ip && env.SIGNIN_PREVIEW_RATE_LIMIT?.limit,503);
      const limit=await env.SIGNIN_PREVIEW_RATE_LIMIT.limit({key:'signin-preview:'+ip});
      failUnless(limit?.success===true,429);
      const secret=env.SIGNIN_PREVIEW_SUPABASE_SERVICE_ROLE;
      failUnless(typeof secret==='string' && secret.length>0,503);
      let backend;
      try { backend=new URL(env.SIGNIN_PREVIEW_SUPABASE_URL); } catch { throw new PreviewError(503); }
      failUnless(backend.protocol==='https:' && /^[a-z0-9]+\.supabase\.co$/.test(backend.hostname) &&
        !backend.username && !backend.password && !backend.port && backend.pathname==='/' && !backend.search && !backend.hash,503);
      const key=backend.origin+':'+route+':'+JSON.stringify(params);
      const time=now(), hit=cache.get(key);
      if(hit && hit.expires>time) return json(hit.data);
      if(hit) cache.delete(key);
      if(!inFlight.has(key)) {
        // Bound simultaneous distinct-key work as well as completed cache keys.
        failUnless(inFlight.size<32,503);
        const task=(async()=>{
          const response=await fetchImpl(backend.origin+'/rest/v1/rpc/signin_preview_'+route,{
            method:'POST',redirect:'manual',credentials:'omit',signal:AbortSignal.timeout(8000),
            headers:{'Content-Type':'application/json',Accept:'application/json',apikey:secret,Authorization:'Bearer '+secret},
            body:JSON.stringify(params),
          });
          // Do not read, log or forward upstream error bodies (may include SQL).
          failUnless(response.ok,502);
          const data=sanitize(await limitedJson(response),route,params);
          failUnless(new TextEncoder().encode(JSON.stringify(data)).byteLength<=MAX_BYTES);
          if(cache.size>=MAX_CACHE_ENTRIES) cache.delete(cache.keys().next().value);
          cache.set(key,{data,expires:now()+TTL_MS});
          return data;
        })();
        inFlight.set(key,task);
      }
      let data;
      try { data=await inFlight.get(key); } finally { inFlight.delete(key); }
      return json(data);
    } catch(error) {
      const status=error instanceof PreviewError ? error.status : 502;
      return json({error:status===400?'invalid_request':status===404?'not_found':
        status===405?'method_not_allowed':status===429?'rate_limited':'preview_unavailable'},status);
    }
  };
}
// Parent owns routing integration; this module never handles ASSETS/auth routes.
const defaultHandler = createSigninPreviewHandler();
export async function handleSignInPreview(request, env, ctx) {
  return defaultHandler(request, env, ctx);
}
