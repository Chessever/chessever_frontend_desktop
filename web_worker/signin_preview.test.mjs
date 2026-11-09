// Test-only synthetic upstream payloads. No live credentials/data are used.
import test from 'node:test';
import assert from 'node:assert/strict';
let createSigninPreviewHandler;
try { ({createSigninPreviewHandler} = await import('./signin_preview.js')); } catch (e) {
  if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
}
const origin = 'https://preview.test';
const request = (path, options={}) => new Request(origin+path,{...options,headers:{'CF-Connecting-IP':'192.0.2.10',...options.headers}});
const env = {SIGNIN_PREVIEW_SUPABASE_URL:'https://fixtureproject.supabase.co',SIGNIN_PREVIEW_SUPABASE_SERVICE_ROLE:'TEST_ONLY_SERVER_SECRET',SIGNIN_PREVIEW_RATE_LIMIT:{limit:async()=>({success:true})}};
const publicGame = {id:'gameA',event_id:'eventA',round_id:'roundA',round_slug:'round-a',tour_id:'tourA',tour_slug:'tour-a',round_starts_at:'2026-11-08T17:00:00Z',fen:null,players:[{name:'White',rating:2500,privateEmail:'do-not-leak'},{name:'Black',rating:2490}],pgn:'DO_NOT_LEAK_PGN',user_id:'DO_NOT_LEAK_USER'};
const eventPayload = {schemaVersion:1,dataset:'for-you',generatedAt:'2026-11-08T18:00:00Z',events:[{id:'eventA',name:'Public Event',created_at:'2026-11-01T00:00:00Z',privateEmail:'do-not-leak'}],games:[publicGame],strictLiveEventIds:['eventA'],missingPositionGameIds:['gameA']};
const upstream = payload=>new Response(JSON.stringify(payload),{headers:{'Content-Type':'application/json'}});

test('only the two read-only exact routes are admitted', async () => {
  assert.equal(typeof createSigninPreviewHandler,'function','read-only handler is missing');
  const handle = createSigninPreviewHandler();
  assert.equal((await handle(request('/api/signin-preview/nope'),{})).status,404);
  assert.equal((await handle(request('/api/signin-preview/events',{method:'POST'}),{})).status,405);
  assert.equal((await handle(request('/api/signin-preview/events?limit=100'),{})).status,400);
  assert.equal((await handle(request('/api/signin-preview/likes?period=all'),{})).status,400);
});

test('events contract keeps canonical rows and actual strict-live IDs, strips nested private data and PGN', async () => {
  let calls=0;
  const handle=createSigninPreviewHandler({fetchImpl:async(url,init)=>{
    calls++;
    assert.equal(url,env.SIGNIN_PREVIEW_SUPABASE_URL+'/rest/v1/rpc/signin_preview_events');
    assert.deepEqual(JSON.parse(init.body),{});
    assert.equal(init.redirect,'manual');
    assert.equal(init.headers.Authorization,'Bearer TEST_ONLY_SERVER_SECRET');
    assert.equal(init.headers.Cookie,undefined);
    return upstream(eventPayload);
  }});
  const response=await handle(request('/api/signin-preview/events',{headers:{Cookie:'private=never-forward',Authorization:'Bearer VISITOR'}}),env);
  assert.equal(response.status,200);
  const result=await response.json();
  assert.equal(result.schemaVersion,1);
  assert.equal(result.dataset,'for-you');
  assert.deepEqual(result.strictLiveEventIds,['eventA']);
  assert.equal(result.games[0].fen,null);
  assert.deepEqual(result.missingPositionGameIds,['gameA']);
  assert.equal(result.games[0].event_id,'eventA');
  assert.equal(result.events[0].id,'eventA');
  assert.doesNotMatch(JSON.stringify(result),/DO_NOT_LEAK|privateEmail|do-not-leak|pgn|TEST_ONLY_SERVER_SECRET|VISITOR/);
  assert.equal(calls,1);
});


const now = Date.parse('2026-11-08T18:00:00Z');
const likesPath=(overrides={})=>'/api/signin-preview/likes?'+new URLSearchParams({period:'today',timeZone:'America/Chicago',from:'2026-11-08T06:00:00Z',to:'2026-11-09T06:00:00Z',...overrides});
const likesPayload={schemaVersion:1,dataset:'community-likes',period:'today',timeZone:'America/Chicago',from:'2026-11-08T06:00:00Z',to:'2026-11-09T06:00:00Z',generatedAt:'2026-11-08T18:00:00Z',rows:[{source_game_id:'gameA',like_count:5}],games:[publicGame],unresolvedGameIds:[],missingPositionGameIds:['gameA']};
test('Likes today/timeZone contract preserves ranks, missing metadata and window without any fallback', async()=>{
  let calls=0;
  const handle=createSigninPreviewHandler({now:()=>now,fetchImpl:async(url,init)=>{
    calls++;
    assert.equal(url,env.SIGNIN_PREVIEW_SUPABASE_URL+'/rest/v1/rpc/signin_preview_likes');
    assert.deepEqual(JSON.parse(init.body),{p_period:'today',p_timezone:'America/Chicago',p_from:'2026-11-08T06:00:00.000Z',p_to:'2026-11-09T06:00:00.000Z'});
    return upstream(likesPayload);
  }});
  const response=await handle(request(likesPath()),env);
  assert.equal(response.status,200);
  const result=await response.json();
  assert.equal(result.schemaVersion,1);
  assert.equal(result.dataset,'community-likes');
  assert.deepEqual(result.rows,likesPayload.rows);
  assert.deepEqual(result.unresolvedGameIds,[]);
  assert.equal(result.games[0].fen,null);
  assert.equal(calls,1);
});


test('local calendar boundaries match Monday, DST 23/25-hour days, months and leap year', async()=>{
  const {currentPreviewWindow:w}=await import('./signin_preview.js');
  assert.deepEqual(w('today','America/Chicago',Date.parse('2026-11-01T18:00:00Z')),{from:'2026-11-01T05:00:00.000Z',to:'2026-11-02T06:00:00.000Z'});
  assert.deepEqual(w('today','America/Chicago',Date.parse('2026-03-08T18:00:00Z')),{from:'2026-03-08T06:00:00.000Z',to:'2026-03-09T05:00:00.000Z'});
  assert.deepEqual(w('week','America/Chicago',now),{from:'2026-11-02T06:00:00.000Z',to:'2026-11-09T06:00:00.000Z'});
  assert.deepEqual(w('month','America/Chicago',now),{from:'2026-11-01T05:00:00.000Z',to:'2026-12-01T06:00:00.000Z'});
  assert.deepEqual(w('year','UTC',Date.parse('2024-02-29T12:00:00Z')),{from:'2024-01-01T00:00:00.000Z',to:'2025-01-01T00:00:00.000Z'});
  assert.deepEqual(w('today','Asia/Kathmandu',now),{from:'2026-11-07T18:15:00.000Z',to:'2026-11-08T18:15:00.000Z'});
});

test('unsupported or historical Likes requests never hit the upstream', async()=>{
  let calls=0;
  const handle=createSigninPreviewHandler({now:()=>now,fetchImpl:async()=>{calls++;return upstream(likesPayload);}});
  const invalid=[likesPath({period:'day'}),likesPath({period:'all'}),likesPath({from:'2026-11-07T06:00:00Z'}),likesPath({to:'2026-11-09T00:00:00Z'}),likesPath({timeZone:'Invalid/Zone'}),likesPath({timeZone:'CST'}),likesPath()+'&cursor=secret',likesPath()+'&period=today','/api/signin-preview/likes?period=week','/api/signin-preview/events?category=current'];
  for(const path of invalid) assert.equal((await handle(request(path),env)).status,400,path);
  assert.equal(calls,0);
});

test('opaque canonical source IDs are preserved literally, not normalized or dropped',async()=>{
  const payload=structuredClone(likesPayload);
  payload.rows[0].source_game_id='gamebase:opaque/source.id';
  payload.games[0].id='gamebase:opaque/source.id';
  payload.missingPositionGameIds=['gamebase:opaque/source.id'];
  const handle=createSigninPreviewHandler({now:()=>now,fetchImpl:async()=>upstream(payload)});
  const response=await handle(request(likesPath()),env);
  assert.equal(response.status,200);
  assert.equal((await response.json()).rows[0].source_game_id,'gamebase:opaque/source.id');
});

test('rate limiter and server config fail closed; cross-origin reads are denied',async()=>{
  let calls=0;
  const handle=createSigninPreviewHandler({fetchImpl:async()=>{calls++;return upstream(eventPayload);}});
  assert.equal((await handle(request('/api/signin-preview/events'),{})).status,503);
  assert.equal((await handle(request('/api/signin-preview/events'),{...env,SIGNIN_PREVIEW_SUPABASE_SERVICE_ROLE:undefined})).status,503);
  assert.equal((await handle(request('/api/signin-preview/events'),{...env,SIGNIN_PREVIEW_RATE_LIMIT:{limit:async()=>({success:false})}})).status,429);
  assert.equal((await handle(request('/api/signin-preview/events'),{...env,SIGNIN_PREVIEW_SUPABASE_URL:'https://attacker.test/'})).status,503);
  assert.equal((await handle(request('/api/signin-preview/events',{headers:{Origin:'https://attacker.test'}}),env)).status,403);
  assert.equal((await handle(request('/api/signin-preview/events',{headers:{'Sec-Fetch-Site':'cross-site'}}),env)).status,403);
  assert.equal(calls,0);
});

test('short bounded cache coalesces requests, expires, and does not bypass rate limits',async()=>{
  let clock=now,calls=0,limits=0;
  const environment={...env,SIGNIN_PREVIEW_RATE_LIMIT:{limit:async()=>{limits++;return {success:limits<=4};}}};
  const handle=createSigninPreviewHandler({now:()=>clock,fetchImpl:async()=>{calls++;await new Promise(r=>setTimeout(r,10));return upstream(eventPayload);}});
  const responses=await Promise.all([handle(request('/api/signin-preview/events'),environment),handle(request('/api/signin-preview/events'),environment)]);
  assert.ok(responses.every(r=>r.status===200));assert.equal(calls,1);
  await handle(request('/api/signin-preview/events'),environment);assert.equal(calls,1);
  clock+=30001;
  assert.equal((await handle(request('/api/signin-preview/events'),environment)).status,200);assert.equal(calls,2);
  assert.equal((await handle(request('/api/signin-preview/events'),environment)).status,429);assert.equal(calls,2);
});

test('upstream errors, redirects, oversized responses and unknown schema never escape',async()=>{
  const variants=[
    ()=>new Response('SQL PRIVATE TEST_ONLY_SERVER_SECRET',{status:403}),
    ()=>new Response(null,{status:302,headers:{Location:'https://attacker.test'}}),
    ()=>upstream({...eventPayload,padding:'x'.repeat(1024*1024)}),
    ()=>upstream({...eventPayload,schemaVersion:2}),
    ()=>upstream({...eventPayload,games:Array(13).fill(publicGame)}),
    ()=>upstream({...eventPayload,strictLiveEventIds:['not-returned']}),
    ()=>new Response('not json',{headers:{'Content-Type':'application/json'}}),
    ()=>{throw new Error('PRIVATE TEST_ONLY_SERVER_SECRET');},
  ];
  for(const variant of variants){
    const handle=createSigninPreviewHandler({fetchImpl:async()=>variant()});
    const response=await handle(request('/api/signin-preview/events'),env);
    assert.equal(response.status,502);
    assert.deepEqual(await response.json(),{error:'preview_unavailable'});
  }
});

test('bad Likes upstream cannot replace a missing ranked row, invent counts, or reorder by non-SQL comparison',async()=>{
  for(const mutate of [p=>p.games.push({...publicGame,id:'substitute'}),p=>p.rows[0].like_count=1,p=>p.rows.push(p.rows[0]),p=>p.rows.reverse(),p=>p.unresolvedGameIds=['not-in-ranking']]){
    const payload=structuredClone(likesPayload);mutate(payload);
    const handle=createSigninPreviewHandler({now:()=>now,fetchImpl:async()=>upstream(payload)});
    assert.equal((await handle(request(likesPath()),env)).status,502);
  }
  const payload=structuredClone(likesPayload);
  payload.rows=[{source_game_id:'zGame',like_count:2},{source_game_id:'AGame',like_count:2}];
  payload.games=[{...publicGame,id:'zGame'},{...publicGame,id:'AGame'}];payload.unresolvedGameIds=[];payload.missingPositionGameIds=['zGame','AGame'];
  const handle=createSigninPreviewHandler({now:()=>now,fetchImpl:async()=>upstream(payload)});
  const response=await handle(request(likesPath()),env);
  assert.equal(response.status,200);
  assert.deepEqual((await response.json()).rows,payload.rows);
});


test('UTC ISO instants reject normalized invalid dates and sub-millisecond nonzero bounds',async()=>{
  const clock=Date.parse('2026-03-02T12:00:00Z');
  let calls=0;
  const handle=createSigninPreviewHandler({now:()=>clock,fetchImpl:async()=>{calls++;return upstream(likesPayload);}});
  const params=new URLSearchParams({period:'today',timeZone:'UTC',from:'2026-02-30T00:00:00Z',to:'2026-03-03T00:00:00Z'});
  assert.equal((await handle(request('/api/signin-preview/likes?'+params),env)).status,400);
  assert.equal((await handle(request(likesPath({from:'2026-11-08T06:00:00.000001Z'})),env)).status,400);
  assert.equal(calls,0);
});

test('diagnostics must exactly expose missing positions, not conceal missing FENs',async()=>{
  const payload=structuredClone(eventPayload);payload.missingPositionGameIds=[];
  const handle=createSigninPreviewHandler({fetchImpl:async()=>upstream(payload)});
  assert.equal((await handle(request('/api/signin-preview/events'),env)).status,502);
});

test('identifiers exceeding the published cap fail rather than being truncated into another ID',async()=>{
  const payload=structuredClone(eventPayload), long='A'.repeat(257);
  payload.games[0].id=long;payload.missingPositionGameIds=[long.slice(0,256)];
  const handle=createSigninPreviewHandler({fetchImpl:async()=>upstream(payload)});
  assert.equal((await handle(request('/api/signin-preview/events'),env)).status,502);
});


test('Games.fromJson-required identity fields are not silently lost; round schedule embed is narrowly compatible',async()=>{
  const handle=createSigninPreviewHandler({fetchImpl:async()=>upstream(eventPayload)});
  const response=await handle(request('/api/signin-preview/events'),env);
  assert.equal(response.status,200);
  const game=(await response.json()).games[0];
  for(const key of ['id','round_id','round_slug','tour_id','tour_slug']) assert.equal(typeof game[key],'string');
  assert.deepEqual(game.round_schedule,{starts_at:'2026-11-08T17:00:00Z',name:null});
  const payload=structuredClone(eventPayload);delete payload.games[0].round_slug;
  const invalid=createSigninPreviewHandler({fetchImpl:async()=>upstream(payload)});
  assert.equal((await invalid(request('/api/signin-preview/events'),env)).status,502);
});


test('unverified/non-public ranked identifiers never leave the server-only RPC boundary', async()=>{
  const payload=structuredClone(likesPayload);
  payload.rows.push({source_game_id:'unverified-private-source',like_count:2});
  payload.unresolvedGameIds=['unverified-private-source'];
  const handle=createSigninPreviewHandler({now:()=>now,fetchImpl:async()=>upstream(payload)});
  const response=await handle(request(likesPath()),env);
  assert.equal(response.status,502);
  assert.deepEqual(await response.json(),{error:'preview_unavailable'});
});

test('metadata is member-bounded, scalar-only, preserves public images and future round clock', async()=>{
  const payload=structuredClone(eventPayload);
  payload.artwork={eventA:{imageUrl:'https://image.lichess.org/actual.png',location:'Prague, Czech Republic',playerCount:42,dominantFederation:'CZE',players:[{privateEmail:'DO_NOT_LEAK'}],info:{sourceUrl:'DO_NOT_LEAK'}}};
  payload.nextRounds={eventA:{name:'Round 5',startsAt:'2026-11-09T12:00:00.123456Z',sourceUrl:'DO_NOT_LEAK',pgn:'DO_NOT_LEAK'}};
  const handle=createSigninPreviewHandler({fetchImpl:async()=>upstream(payload)});
  const response=await handle(request('/api/signin-preview/events'),env);
  assert.equal(response.status,200);
  const result=await response.json();
  assert.deepEqual(result.artwork,{eventA:{imageUrl:'https://image.lichess.org/actual.png',location:'Prague, Czech Republic',playerCount:42,dominantFederation:'CZE'}});
  assert.deepEqual(result.nextRounds,{eventA:{name:'Round 5',startsAt:'2026-11-09T12:00:00.123456Z'}});
  assert.equal(result.generatedAt,payload.generatedAt);
  assert.doesNotMatch(JSON.stringify(result.artwork)+JSON.stringify(result.nextRounds),/DO_NOT_LEAK|players|sourceUrl|pgn|info/);
  for(const mutate of [
    p=>p.artwork.other=p.artwork.eventA,
    p=>p.nextRounds.other=p.nextRounds.eventA,
    p=>p.artwork.eventA.imageUrl='javascript:alert(1)',
    p=>p.artwork.eventA.imageUrl='https://user:password@images.test/a',
    p=>p.artwork.eventA.imageUrl='https://images.test/'+ 'a'.repeat(2048),
    p=>p.artwork.eventA.location={nested:'bad'},
    p=>p.artwork.eventA.playerCount='42',
    p=>p.artwork.eventA.playerCount=-1,
    p=>p.artwork.eventA.dominantFederation=['CZE'],
    p=>p.nextRounds.eventA.startsAt=p.generatedAt,
    p=>p.nextRounds.eventA.startsAt='2026-02-30T12:00:00Z',
    p=>p.nextRounds.eventA.name={nested:'bad'},
  ]) {
    const bad=structuredClone(payload);mutate(bad);
    const denied=createSigninPreviewHandler({fetchImpl:async()=>upstream(bad)});
    assert.equal((await denied(request('/api/signin-preview/events'),env)).status,502);
  }
});

test('non-numeric aggregate counts are not coerced into successful likes', async()=>{
  for(const count of [null,['5'],'5',{},true]) {
    const payload=structuredClone(likesPayload);payload.rows[0].like_count=count;
    const handle=createSigninPreviewHandler({now:()=>now,fetchImpl:async()=>upstream(payload)});
    assert.equal((await handle(request(likesPath()),env)).status,502);
  }
});
