// ============================================================================
// app/login.tsx — email OTP in two steps.
//   Step 1: email + name + role  → Supabase emails a 6-digit code
//   Step 2: enter the code       → session created → gatekeeper routes home
//
// The role choice only matters the FIRST time an email signs up — it's baked
// into the profile by the database trigger. Later logins ignore it.
// ============================================================================

import { useState } from 'react';
import {
  View, Text, TextInput, TouchableOpacity, StyleSheet,
  ActivityIndicator, KeyboardAvoidingView, Platform,
} from 'react-native';
import { supabase } from '../lib/supabase';
import { colors, spacing, radius } from '../lib/theme';

type Role = 'buyer' | 'seller';

export default function Login() {
  const [step, setStep] = useState<'details' | 'code'>('details');
  const [email, setEmail] = useState('');
  const [name, setName] = useState('');
  const [role, setRole] = useState<Role>('buyer');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const sendCode = async () => {
    const cleanEmail = email.trim().toLowerCase();
    if (!cleanEmail.includes('@')) return setError('Enter a valid email address.');
    if (name.trim().length < 2) return setError('Enter your name (2+ characters).');

    setError('');
    setBusy(true);
    const { error: err } = await supabase.auth.signInWithOtp({
      email: cleanEmail,
      options: {
        shouldCreateUser: true,
        data: { display_name: name.trim(), role }, // read by the signup trigger
      },
    });
    setBusy(false);
    if (err) setError(err.message);
    else setStep('code');
  };

  const verifyCode = async () => {
    if (code.trim().length < 6) return setError('Enter the 6-digit code from your email.');
    setError('');
    setBusy(true);
    const { error: err } = await supabase.auth.verifyOtp({
      email: email.trim().toLowerCase(),
      token: code.trim(),
      type: 'email',
    });
    setBusy(false);
    if (err) setError(err.message);
    // on success the gatekeeper redirects to /home automatically
  };

  return (
    <KeyboardAvoidingView
      style={styles.screen}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      <View style={styles.container}>
        <Text style={styles.logo}>Trust<Text style={{ color: colors.primary }}>Pay</Text></Text>
        <Text style={styles.tagline}>فلوسك محمية — your money, protected</Text>

        {step === 'details' ? (
          <>
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

            <TouchableOpacity style={styles.cta} onPress={sendCode} disabled={busy}>
              {busy ? <ActivityIndicator color={colors.white} />
                    : <Text style={styles.ctaText}>Send me a code</Text>}
            </TouchableOpacity>
          </>
        ) : (
          <>
            <Text style={styles.hint}>
              We emailed a 6-digit code to {email.trim().toLowerCase()}
            </Text>
            <TextInput
              style={[styles.input, styles.codeInput]}
              placeholder="······"
              placeholderTextColor={colors.gray}
              keyboardType="number-pad"
              maxLength={6}
              value={code}
              onChangeText={setCode}
            />
            <TouchableOpacity style={styles.cta} onPress={verifyCode} disabled={busy}>
              {busy ? <ActivityIndicator color={colors.white} />
                    : <Text style={styles.ctaText}>Verify & enter</Text>}
            </TouchableOpacity>
            <TouchableOpacity onPress={() => { setStep('details'); setCode(''); }}>
              <Text style={styles.backLink}>← change email</Text>
            </TouchableOpacity>
          </>
        )}

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
  input: {
    backgroundColor: colors.card, borderWidth: 1, borderColor: colors.grayLight,
    borderRadius: radius.md, padding: spacing.md, fontSize: 16,
    marginBottom: spacing.sm, color: colors.black,
  },
  codeInput: { textAlign: 'center', fontSize: 28, letterSpacing: 12 },
  roleRow: { flexDirection: 'row', gap: spacing.sm, marginBottom: spacing.md },
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
  hint: { color: colors.gray, textAlign: 'center', marginBottom: spacing.md },
  backLink: { color: colors.gray, textAlign: 'center', marginTop: spacing.md },
  error: { color: colors.danger, textAlign: 'center', marginTop: spacing.md },
});
