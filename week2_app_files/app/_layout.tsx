// ============================================================================
// app/_layout.tsx — the gatekeeper.
// Watches the auth session: no session → /login, session → /home.
// Every screen in the app lives inside this Stack.
// ============================================================================

import { useEffect, useState } from 'react';
import { ActivityIndicator, View } from 'react-native';
import { Stack, useRouter, useSegments } from 'expo-router';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '../lib/supabase';
import { colors } from '../lib/theme';

export default function RootLayout() {
  const [session, setSession] = useState<Session | null>(null);
  const [booting, setBooting] = useState(true);
  const router = useRouter();
  const segments = useSegments();

  // 1) load any saved session, then keep listening for login/logout
  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setBooting(false);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s);
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  // 2) route based on session
  useEffect(() => {
    if (booting) return;
    const onLoginScreen = segments[0] === 'login';
    if (!session && !onLoginScreen) router.replace('/login');
    if (session && onLoginScreen) router.replace('/home');
  }, [session, booting, segments]);

  if (booting) {
    return (
      <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center' }}>
        <ActivityIndicator size="large" color={colors.primary} />
      </View>
    );
  }

  return <Stack screenOptions={{ headerShown: false }} />;
}
