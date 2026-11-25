import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createGamebaseProxyHandler } from "./handler.ts";

Deno.serve(
  createGamebaseProxyHandler({
    env: (name) => Deno.env.get(name),
    fetch: (input, init) => fetch(input, init),
  }),
);
