import { handler } from "../_shared/apple/handlers.ts";
import { dependencies } from "../_shared/apple/runtime.ts";
Deno.serve(handler("worker", dependencies));
