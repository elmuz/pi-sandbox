/**
 * Container-only footer marker.
 *
 * bin/pi-sandbox loads this extension explicitly with --extension, so host Pi
 * instances never see the marker. The status line appears below the built-in
 * footer and leaves the rest of the footer untouched.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const STATUS_KEY = "00-pi-sandbox";
const PROJECT = process.env.PI_SANDBOX_PROJECT?.trim();
const MARKER = PROJECT ? `⬢ sandbox • ${PROJECT}` : "⬢ sandbox";

function show(ctx: ExtensionContext): void {
  if (ctx.mode !== "tui") return;
  ctx.ui.setStatus(STATUS_KEY, ctx.ui.theme.fg("accent", MARKER));
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => show(ctx));
  pi.on("session_shutdown", (_event, ctx) => {
    ctx.ui.setStatus(STATUS_KEY, undefined);
  });
}
