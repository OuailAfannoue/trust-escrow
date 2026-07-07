// ============================================================================
// app/home.tsx — the wallet, live from the real ledger.
// Every number on this screen is computed by the database from the
// append-only ledger you attack-tested. Nothing here is stored or faked.
// ============================================================================

import { useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator, Alert,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text, TouchableOpacity,
  View,
} from 'react-native';
import { supabase } from '../lib/supabase';
import { colors, money, radius, spacing } from '../lib/theme';

type Wallet = { available_mad: number; cashback_pending_mad: number };
type Profile = { display_name: string; role: string };

export default function Home() {
  const router = useRouter();
  const [wallet, setWallet] = useState<Wallet | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [busy, setBusy] = useState(false);

  const fetchAll = useCallback(async () => {
    const [{ data: w, error: we }, { data: p }] = await Promise.all([
      supabase.rpc('rpc_my_wallet'),
      supabase.from('profiles').select('display_name, role').single(), // RLS: own row only
    ]);
    if (we) Alert.alert('Error', we.message);
    if (w) setWallet(w as Wallet);
    if (p) setProfile(p as Profile);
  }, []);

  useEffect(() => { fetchAll(); }, [fetchAll]);

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchAll();
    setRefreshing(false);
  };

  const demoTopup = async () => {
    setBusy(true);
    const { error } = await supabase.rpc('rpc_topup', { p_amount: 500 });
    setBusy(false);
    if (error) Alert.alert('Top-up failed', error.message);
    else fetchAll();
  };

  const signOut = () => supabase.auth.signOut();

  return (
    <ScrollView
      style={styles.screen}
      contentContainerStyle={styles.content}
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
    >
      {/* header */}
      <View style={styles.headerRow}>
        <View>
          <Text style={styles.hello}>Salam,</Text>
          <Text style={styles.name}>{profile?.display_name ?? '...'}</Text>
        </View>
        {profile && (
          <View style={styles.roleBadge}>
            <Text style={styles.roleBadgeText}>{profile.role}</Text>
          </View>
        )}
      </View>

      {/* the wallet card */}
      <View style={styles.walletCard}>
        <Text style={styles.walletLabel}>Available balance</Text>
        {wallet ? (
          <Text style={styles.walletAmount}>{money(wallet.available_mad)}</Text>
        ) : (
          <ActivityIndicator color={colors.primary} style={{ marginVertical: 12 }} />
        )}
        <View style={styles.cashbackRow}>
          <Text style={styles.cashbackLabel}>Pending cashback</Text>
          <Text style={styles.cashbackAmount}>
            {wallet ? money(wallet.cashback_pending_mad) : '—'}
          </Text>
        </View>
      </View>

      {/* demo top-up (replaced by real cash-in via BaaS partner later) */}
      <TouchableOpacity style={styles.topupBtn} onPress={demoTopup} disabled={busy}>
        {busy ? <ActivityIndicator color={colors.white} />
              : <Text style={styles.topupText}>+ Add 500 MAD (demo)</Text>}
      </TouchableOpacity>
      <Text style={styles.note}>
        Demo top-up simulates a cash-in at an agent. Pull down to refresh —
        every balance is computed live from the escrow ledger.
      </Text>

      {profile?.role === 'seller' && (
        <TouchableOpacity style={styles.sellerBtn} onPress={() => router.push('/products')}>
          <Text style={styles.sellerBtnText}>🛍  My products & payment links  →</Text>
        </TouchableOpacity>
      )}
      {profile?.role === 'buyer' && (
        <TouchableOpacity style={styles.sellerBtn} onPress={() => router.push('/buy')}>
          <Text style={styles.sellerBtnText}>🛒  Buy with a code  →</Text>
        </TouchableOpacity>
      )}
      <TouchableOpacity style={styles.ordersBtn} onPress={() => router.push('/orders')}>
        <Text style={styles.ordersBtnText}>📦  My orders  →</Text>
      </TouchableOpacity>

      <TouchableOpacity onPress={signOut}>
        <Text style={styles.signOut}>Sign out</Text>
      </TouchableOpacity>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.surface },
  content: { padding: spacing.lg, paddingTop: 70 },
  headerRow: {
    flexDirection: 'row', justifyContent: 'space-between',
    alignItems: 'center', marginBottom: spacing.lg,
  },
  hello: { color: colors.gray, fontSize: 15 },
  name: { color: colors.black, fontSize: 24, fontWeight: '800' },
  roleBadge: {
    backgroundColor: colors.black, paddingHorizontal: spacing.md,
    paddingVertical: spacing.xs, borderRadius: radius.pill,
  },
  roleBadgeText: { color: colors.white, fontWeight: '700', textTransform: 'capitalize' },
  walletCard: {
    backgroundColor: colors.black, borderRadius: radius.lg,
    padding: spacing.lg, marginBottom: spacing.md,
  },
  walletLabel: { color: '#9CA3AF', fontSize: 14 },
  walletAmount: { color: colors.white, fontSize: 38, fontWeight: '800', marginVertical: 6 },
  cashbackRow: {
    flexDirection: 'row', justifyContent: 'space-between',
    borderTopWidth: 1, borderTopColor: '#1F2937', paddingTop: spacing.sm,
  },
  cashbackLabel: { color: '#9CA3AF' },
  cashbackAmount: { color: colors.primary, fontWeight: '700' },
  topupBtn: {
    backgroundColor: colors.primary, borderRadius: radius.md,
    padding: spacing.md, alignItems: 'center',
  },
  topupText: { color: colors.white, fontSize: 16, fontWeight: '700' },
  note: { color: colors.gray, fontSize: 13, marginTop: spacing.md, lineHeight: 18 },
  sellerBtn: {
    backgroundColor: colors.black, borderRadius: radius.md,
    padding: spacing.md, alignItems: 'center', marginTop: spacing.md,
  },
  sellerBtnText: { color: colors.white, fontSize: 16, fontWeight: '700' },
  ordersBtn: {
    backgroundColor: colors.card, borderWidth: 1, borderColor: colors.grayLight,
    borderRadius: radius.md, padding: spacing.md, alignItems: 'center',
    marginTop: spacing.sm,
  },
  ordersBtnText: { color: colors.black, fontSize: 16, fontWeight: '700' },
  signOut: { color: colors.danger, textAlign: 'center', marginTop: spacing.xl, fontWeight: '600' },
});
