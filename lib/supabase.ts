// ============================================================================
// lib/supabase.ts — the app's single connection to your backend.
//
// PASTE YOUR TWO VALUES BELOW (Supabase Dashboard → Settings → API):
//   1. Project URL        → looks like https://abcdefgh.supabase.co
//   2. anon public key    → long string starting with "eyJ..."
//
// The anon key is DESIGNED to ship inside the app — everything it can touch
// is gated by the RLS policies and RPC layer we installed in file 05.
// NEVER put the service_role key in app code.
// ============================================================================

import AsyncStorage from '@react-native-async-storage/async-storage';
import { createClient } from '@supabase/supabase-js';
import 'react-native-url-polyfill/auto';

const SUPABASE_URL = 'https://knelduzguqdagtyifzxr.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_hABjGfVBGxoPEeQsmwhhIQ_uEt3A0Is';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    storage: AsyncStorage,      // session survives app restarts
    autoRefreshToken: true,     // stays logged in
    persistSession: true,
    detectSessionInUrl: false,  // no browser URL handling on native
  },
});
