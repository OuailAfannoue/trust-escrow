// ============================================================================
// app/buy.tsx — the buyer's entry into escrow.
//   1) enter the seller's code  → preview the (soon-to-be-frozen) listing
//   2) "Pay into escrow"        → order created + money locked, atomically
// If the deposit fails (e.g. not enough funds), the freshly created order is
// cancelled on the spot — no dangling half-orders.
// ============================================================================

import { useRouter } from 'expo-router';
import { useState } from 'react';
import {
  ActivityIndicator, Alert,
  Image,
  ScrollView,
  StyleSheet,
  Text, TextInput, TouchableOpacity,
  View,
} from 'react-native';
import { supabase } from '../lib/supabase';
import { colors, money, radius, spacing } from '../lib/theme';

const SHIPPING = 35;
const CASHBACK = 25;

type Preview = {
  slug: string;
  usable: boolean;
  product: {
    title: string; description: string; category: string;
    condition: string; price_mad: number; photos: string[];
  };
  seller: { id: string; display_name: string };
};

export default function Buy() {
  const router = useRouter();
  const [code, setCode] = useState('');
  const [preview, setPreview] = useState<Preview | null>(null);
  const [busy, setBusy] = useState(false);

  const lookup = async () => {
    const slug = code.trim().toLowerCase();
    if (slug.length < 6) return Alert.alert('Hmm', 'Enter the full payment code.');
    setBusy(true);
    const { data, error } = await supabase.rpc('rpc_get_link_preview', { p_slug: slug });
    setBusy(false);
    if (error) return Alert.alert('Not found', error.message);
    if (!(data as Preview).usable)
      return Alert.alert('Unavailable', 'This payment link is no longer active.');
    setPreview(data as Preview);
  };

  const pay = async () => {
    if (!preview) return;
    setBusy(true);
    try {
      // pre-check the wallet so we fail with a friendly message
      const total = Number(preview.product.price_mad) + SHIPPING;
      const { data: w } = await supabase.rpc('rpc_my_wallet');
      const available = Number(w?.available_mad ?? 0);
      if (available < total) {
        throw new Error(
          `This costs ${total.toFixed(2)} MAD (product + shipping) but your wallet has ` +
          `${available.toFixed(2)} MAD. Top up on the home screen first.`
        );
      }

      // 1) create the order (freezes the listing snapshot)
      const { data: orderId, error: e1 } = await supabase.rpc('rpc_create_order', {
        p_slug: preview.slug,
        p_shipping: SHIPPING,
      });
      if (e1) throw new Error(e1.message);

      // 2) lock the money — and clean up the order if this fails
      const { error: e2 } = await supabase.rpc('rpc_deposit', { p_order: orderId });
      if (e2) {
        await supabase.rpc('rpc_cancel_order', { p_order: orderId });
        throw new Error(e2.message);
      }

      setBusy(false);
      Alert.alert(
        '🔒 Money locked',
        `${money(total)} is now in escrow. The seller has been cleared to ship. ` +
        `You release the money ONLY when you inspect and confirm the delivery.`,
        [{ text: 'View my order', onPress: () => router.replace('/orders') }]
      );
    } catch (e: any) {
      setBusy(false);
      Alert.alert('Payment not completed', e.message);
    }
  };

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <TouchableOpacity onPress={() => (preview ? setPreview(null) : router.back())}>
        <Text style={styles.back}>← Back</Text>
      </TouchableOpacity>

      {!preview ? (
        <>
          <Text style={styles.h1}>Buy with a code</Text>
          <Text style={styles.sub}>
            Paste the payment code the seller sent you (WhatsApp, Instagram...).
          </Text>
          <TextInput
            style={styles.codeInput}
            placeholder="e.g. ni4njd8q"
            placeholderTextColor={colors.gray}
            autoCapitalize="none"
            autoCorrect={false}
            value={code}
            onChangeText={setCode}
          />
          <TouchableOpacity style={styles.cta} onPress={lookup} disabled={busy}>
            {busy ? <ActivityIndicator color={colors.white} />
                  : <Text style={styles.ctaText}>Find the product</Text>}
          </TouchableOpacity>
        </>
      ) : (
        <>
          {/* photos */}
          <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.photoStrip}>
            {preview.product.photos?.map((u) => (
              <Image key={u} source={{ uri: u }} style={styles.photo} />
            ))}
          </ScrollView>

          <Text style={styles.title}>{preview.product.title}</Text>
          <Text style={styles.meta}>
            {preview.product.category} · {preview.product.condition.replace('_', ' ')} · sold by{' '}
            <Text style={{ fontWeight: '700', color: colors.black }}>
              {preview.seller.display_name}
            </Text>
          </Text>
          <Text style={styles.desc}>{preview.product.description}</Text>

          {/* the escrow receipt */}
          <View style={styles.receipt}>
            <Row label="Product" value={money(preview.product.price_mad)} />
            <Row label="Shipping" value={money(SHIPPING)} />
            <Row label="Cashback after you confirm" value={`+${money(CASHBACK)}`} green />
            <View style={styles.receiptDivider} />
            <Row
              label="Locked in escrow"
              value={money(Number(preview.product.price_mad) + SHIPPING)}
              bold
            />
          </View>

          <Text style={styles.protect}>
            🛡 Your money stays frozen until YOU confirm the delivery in person.
            Reject at the door → the product amount returns to you instantly.
          </Text>

          <TouchableOpacity style={styles.cta} onPress={pay} disabled={busy}>
            {busy ? <ActivityIndicator color={colors.white} />
                  : <Text style={styles.ctaText}>🔒 Pay into escrow</Text>}
          </TouchableOpacity>
        </>
      )}
    </ScrollView>
  );
}

function Row({ label, value, bold, green }:
  { label: string; value: string; bold?: boolean; green?: boolean }) {
  return (
    <View style={styles.row}>
      <Text style={[styles.rowLabel, bold && styles.rowBold]}>{label}</Text>
      <Text style={[styles.rowValue, bold && styles.rowBold, green && { color: colors.primary }]}>
        {value}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.surface },
  content: { padding: spacing.lg, paddingTop: 60, paddingBottom: 60 },
  back: { color: colors.gray, marginBottom: spacing.sm },
  h1: { fontSize: 26, fontWeight: '800', color: colors.black },
  sub: { color: colors.gray, marginTop: 4, marginBottom: spacing.md },
  codeInput: {
    backgroundColor: colors.card, borderWidth: 1, borderColor: colors.grayLight,
    borderRadius: radius.md, padding: spacing.md, fontSize: 22,
    textAlign: 'center', letterSpacing: 4, color: colors.black,
    marginBottom: spacing.sm,
  },
  photoStrip: { marginBottom: spacing.md },
  photo: { width: 220, height: 220, borderRadius: radius.lg, marginRight: spacing.sm },
  title: { fontSize: 22, fontWeight: '800', color: colors.black },
  meta: { color: colors.gray, marginTop: 2, marginBottom: spacing.sm },
  desc: { color: colors.black, lineHeight: 20, marginBottom: spacing.md },
  receipt: {
    backgroundColor: colors.card, borderRadius: radius.lg,
    borderWidth: 1, borderColor: colors.grayLight, padding: spacing.md,
  },
  row: { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 4 },
  rowLabel: { color: colors.gray },
  rowValue: { color: colors.black, fontWeight: '600' },
  rowBold: { fontWeight: '800', color: colors.black, fontSize: 16 },
  receiptDivider: { height: 1, backgroundColor: colors.grayLight, marginVertical: 6 },
  protect: { color: colors.gray, fontSize: 13, lineHeight: 19, marginVertical: spacing.md },
  cta: {
    backgroundColor: colors.primary, borderRadius: radius.md,
    padding: spacing.md, alignItems: 'center',
  },
  ctaText: { color: colors.white, fontSize: 17, fontWeight: '700' },
});
