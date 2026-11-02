// Twilio calls this link when someone calls the Kvisa number, and we answer with
// "ring this cell phone". It only returns forwarding instructions and touches no data,
// so it needs no login (Twilio can't send one). Deployed with verify_jwt off.
const FORWARD_TO = '+18455585118';

Deno.serve(() => new Response(
  `<?xml version="1.0" encoding="UTF-8"?>\n<Response><Dial timeout="30">${FORWARD_TO}</Dial></Response>`,
  { headers: { 'Content-Type': 'text/xml' } },
));
