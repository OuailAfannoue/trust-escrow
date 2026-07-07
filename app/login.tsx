// ============================================================================
// app/login.tsx — email + password, two modes: create account / sign in.
// No email delivery involved (requires "Confirm email" OFF in the dashboard).
// Phone OTP replaces this before launch — one screen swap, nothing else moves.
// ============================================================================

import { useState } from 'react';
import {
  ActivityIndicator, KeyboardAvoidingView, Platform,
  StyleSheet,
  Text, TextInput, TouchableOpacity,
  View,
} from 'react-native';
import { supabase } from '../lib/supabase';
import { colors, radius, spacing } from '../lib/theme';

type Role = 'buyer' | 'seller';
type Mode = 'signup' | 'signin';

export default function Login() {
  const [mode, setMode] = useState<Mode>('signup');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [name, setName] = useState('');
  const [role, setRole] = useState<Role>('buyer');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const submit = async () => {
    const cleanEmail = email.trim().toLowerCase();
    if (!cleanEmail.includes('@')) return setError('Enter a valid email address.');
    if (password.length < 6) return setError('Password must be at least 6 characters.');
    if (mode === 'signup' && name.trim().length < 2)
      return setError('Enter your name (2+ characters).');

    setError('');
    setBusy(true);

    const { error: err } =
      mode === 'signup'
        ? await supabase.auth.signUp({
            email: cleanEmail,
            password,
            options: { data: { display_name: name.trim(), role } }, // read by signup trigger
          })
        : await supabase.auth.signInWithPassword({ email: cleanEmail, password });

    setBusy(false);
    if (err) {
      if (err.message.toLowerCase().includes('already registered')) {
        setError('This email already has an account — switch to Sign in.');
      } else {
        setError(err.message);
      }
    }
    // on success the gatekeeper in _layout.tsx routes to /home automatically
  };

  return (
    <KeyboardAvoidingView
      style={styles.screen}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      <View style={styles.container}>
        <Text style={styles.logo}>Trust<Text style={{ color: colors.primary }}>Pay</Text></Text>
        <Text style={styles.tagline}>فلوسك محمية — your money, protected</Text>

        {/* mode switch */}
        <View style={styles.modeRow}>
          {(['signup', 'signin'] as Mode[]).map((m) => (
            <TouchableOpacity
              key={m}
              style={[styles.modeBtn, mode === m && styles.modeBtnActive]}
              onPress={() => { setMode(m); setError(''); }}
            >
              <Text style={[styles.modeText, mode === m && styles.modeTextActive]}>
                {m === 'signup' ? 'Create account' : 'Sign in'}
              </Text>
            </TouchableOpacity>
          ))}
        </View>

        <TextInput
          style={styles.input}
          placeholder="Email address"
          placeholderTextColor={colors.gray}
          autoCapitalize="none"
          keyboardType="email-address"
          value={email}
          onChangeText={setEmail}
        />
        <TextInput
          style={styles.input}
          placeholder="Password (6+ characters)"
          placeholderTextColor={colors.gray}
          secureTextEntry
          value={password}
          onChangeText={setPassword}
        />

        {mode === 'signup' && (
          <>
            <TextInput
              style={styles.input}
              placeholder="Your name"
              placeholderTextColor={colors.gray}
              value={name}
              onChangeText={setName}
            />
            <View style={styles.roleRow}>
              {(['buyer', 'seller'] as Role[]).map((r) => (
                <TouchableOpacity
                  key={r}
                  style={[styles.roleBtn, role === r && styles.roleBtnActive]}
                  onPress={() => setRole(r)}
                >
                  <Text style={[styles.roleText, role === r && styles.roleTextActive]}>
                    {r === 'buyer' ? 'I buy' : 'I sell'}
                  </Text>
                </TouchableOpacity>
              ))}
            </View>
          </>
        )}

        <TouchableOpacity style={styles.cta} onPress={submit} disabled={busy}>
          {busy ? <ActivityIndicator color={colors.white} />
                : <Text style={styles.ctaText}>
                    {mode === 'signup' ? 'Create my wallet' : 'Sign in'}
                  </Text>}
        </TouchableOpacity>

        {error ? <Text style={styles.error}>{error}</Text> : null}
      </View>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.surface },
  container: { flex: 1, justifyContent: 'center', padding: spacing.lg },
  logo: { fontSize: 40, fontWeight: '800', color: colors.black, textAlign: 'center' },
  tagline: { textAlign: 'center', color: colors.gray, marginBottom: spacing.xl },
  modeRow: {
    flexDirection: 'row', backgroundColor: colors.grayLight,
    borderRadius: radius.pill, padding: 4, marginBottom: spacing.md,
  },
  modeBtn: { flex: 1, padding: spacing.sm, borderRadius: radius.pill, alignItems: 'center' },
  modeBtnActive: { backgroundColor: colors.white },
  modeText: { color: colors.gray, fontWeight: '600' },
  modeTextActive: { color: colors.black },
  input: {
    backgroundColor: colors.card, borderWidth: 1, borderColor: colors.grayLight,
    borderRadius: radius.md, padding: spacing.md, fontSize: 16,
    marginBottom: spacing.sm, color: colors.black,
  },
  roleRow: { flexDirection: 'row', gap: spacing.sm, marginBottom: spacing.sm },
  roleBtn: {
    flex: 1, padding: spacing.md, borderRadius: radius.md, alignItems: 'center',
    borderWidth: 1, borderColor: colors.grayLight, backgroundColor: colors.card,
  },
  roleBtnActive: { backgroundColor: colors.black, borderColor: colors.black },
  roleText: { color: colors.gray, fontWeight: '600' },
  roleTextActive: { color: colors.white },
  cta: {
    backgroundColor: colors.primary, borderRadius: radius.md,
    padding: spacing.md, alignItems: 'center', marginTop: spacing.xs,
  },
  ctaText: { color: colors.white, fontSize: 17, fontWeight: '700' },
  error: { color: colors.danger, textAlign: 'center', marginTop: spacing.md },
});