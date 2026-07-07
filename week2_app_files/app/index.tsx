// app/index.tsx — the "/" route. Just hands off to /home;
// the gatekeeper in _layout.tsx bounces to /login if not signed in.

import { Redirect } from 'expo-router';

export default function Index() {
  return <Redirect href="/home" />;
}
