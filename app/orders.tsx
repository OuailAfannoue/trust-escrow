// ============================================================================
// app/orders.tsx — the escrow dance floor, for both roles.
// Each card renders from the FROZEN product snapshot (not the live listing)
// and offers exactly the actions the state machine allows for your role:
//   seller + escrow_locked  → Mark shipped (or decline & refund)
//   buyer  + in_transit     → Confirm ✓ / Reject ✗
//   buyer  + pending_deposit→ Pay now / Cancel
// Anything else is display-only — just like the database would enforce anyway.
// ============================================================================

import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import {
  Alert,
  FlatList,
  Image, RefreshControl,
  StyleSheet,
  Text, TouchableOpacity,
  View,
} from 'react-native';
import { supabase } from '../lib/supabase';
import { colors, money, radius, spacing } from '../lib/theme';

type Order = {
  id: string; status: string; buyer_id: string; seller_id: string;
  amount_product: number; amount_shipping: number; cashback_mad: number;
  created_at: string;
  product_snapshot: { title: string; photos: string[]; price_mad: number };
};

const STATUS_UI: Record<string, { label: string; color: string }> = {
  pending_deposit:     { label: 'Awaiting payment',              color: colors.gray },
  escrow_locked:       { label: '🔒 Locked — awaiting shipment', color: colors.primary },
  in_transit:          { label: '🚚 On the way',                 color: colors.black },
  delivered_confirmed: { label: '✓ Delivered & released',        color: colors.primary },
  delivery_rejected:   { label: '✗ Rejected — refunded',         color: colors.danger },
  disputed:            { label: '⚖ In dispute',                  color: colors.danger },
  cancelled:           { label: 'Cancelled',                     color: colors.gray },
};

export default function Orders() {
  const router = useRouter();
  const [me, setMe] = useState<string | null>(null);
  const [orders, setOrders] = useState<Order[]>([]);
  const [refreshing, setRefreshing] = useState(false);
  const [loaded, setLoaded] = useState(false);

  const fetchAll = useCallback(async () => {
    const { data: prof } = await supabase.from('profiles').select('id').single();
    if (prof) setMe(prof.id);
    const { data } = await supabase
      .from('orders')
      .select('id, status, buyer_id, seller_id, amount_product, amount_shipping, cashback_mad, created_at, product_snapshot')
      .order('created_at', { ascending: false });
    setOrders((data as Order[]) ?? []);
    setLoaded(true);
  }, []);

  useFocusEffect(useCallback(() => { fetchAll(); }, [fetchAll]));

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchAll();
    setRefreshing(false);
  };

  const act = async (rpc: string, params: Record<string, unknown>, successMsg: string) => {
    const { error } = await supabase.rpc(rpc, params);
    if (error) Alert.alert('Not allowed', error.message);
    else {
      if (successMsg) Alert.alert(successMsg);
      fetchAll();
    }
  };

  const confirmDelivery = (o: Order) =>
    Alert.alert(
      'Confirm delivery?',
      `You inspected the package and accept it. ${money(Number(o.amount_product) + Number(o.amount_shipping))} ` +
      `is released to the seller INSTANTLY, and you earn ${money(o.cashback_mad)} cashback.`,
      [
        { text: 'Not yet', style: 'cancel' },
        { text: 'Confirm ✓', onPress: () => act('rpc_confirm_delivery', { p_order: o.id }, '✓ Released. Cashback earned!') },
      ]
    );

  const rejectDelivery = (o: Order) =>
    Alert.alert(
      'Reject delivery?',
      `${money(o.amount_product)} returns to your wallet instantly. ` +
      `Shipping (${money(o.amount_shipping)}) stays paid — the trip happened.`,
      [
        { text: 'Keep inspecting', style: 'cancel' },
        {
          text: 'Reject ✗', style: 'destructive',
          onPress: () => act('rpc_reject_delivery',
            { p_order: o.id, p_note: 'Rejected at handoff by buyer' },
            'Refund sent to your wallet.'),
        },
      ]
    );

  const renderItem = ({ item }: { item: Order }) => {
    const iAmBuyer = item.buyer_id === me;
    const ui = STATUS_UI[item.status] ?? { label: item.status, color: colors.gray };
    const total = Number(item.amount_product) + Number(item.amount_shipping);

    return (
      <View style={styles.card}>
        <View style={styles.cardTop}>
          {item.product_snapshot?.photos?.[0] ? (
            <Image source={{ uri: item.product_snapshot.photos[0] }} style={styles.thumb} />
          ) : (
            <View style={[styles.thumb, { backgroundColor: colors.grayLight }]} />
          )}
          <View style={{ flex: 1 }}>
            <Text style={styles.title} numberOfLines={2}>
              {item.product_snapshot?.title ?? 'Order'}
            </Text>
            <Text style={styles.total}>{money(total)}</Text>
            <Text style={styles.roleTag}>
              {iAmBuyer ? "You're the buyer" : "You're the seller"}
            </Text>
          </View>
        </View>

        <Text style={[styles.status, { color: ui.color }]}>{ui.label}</Text>

        {/* the actions this role + state actually allows */}
        {!iAmBuyer && item.status === 'escrow_locked' && (
          <View style={styles.actionRow}>
            <TouchableOpacity
              style={styles.primaryBtn}
              onPress={() => act('rpc_mark_shipped',
                { p_order: item.id, p_courier_phone: null }, '🚚 Marked as shipped.')}
            >
              <Text style={styles.primaryBtnText}>Mark shipped</Text>
            </TouchableOpacity>
            <TouchableOpacity
              onPress={() =>
                Alert.alert('Decline this sale?', 'Full amount refunds to the buyer.', [
                  { text: 'No', style: 'cancel' },
                  { text: 'Decline & refund', style: 'destructive',
                    onPress: () => act('rpc_cancel_order', { p_order: item.id }, 'Order cancelled, buyer refunded.') },
                ])}
            >
              <Text style={styles.linkDanger}>Decline & refund</Text>
            </TouchableOpacity>
          </View>
        )}

        {iAmBuyer && item.status === 'in_transit' && (
          <View style={styles.actionRow}>
            <TouchableOpacity style={styles.primaryBtn} onPress={() => confirmDelivery(item)}>
              <Text style={styles.primaryBtnText}>Confirm ✓</Text>
            </TouchableOpacity>
            <TouchableOpacity style={styles.dangerBtn} onPress={() => rejectDelivery(item)}>
              <Text style={styles.dangerBtnText}>Reject ✗</Text>
            </TouchableOpacity>
          </View>
        )}

        {iAmBuyer && item.status === 'pending_deposit' && (
          <View style={styles.actionRow}>
            <TouchableOpacity
              style={styles.primaryBtn}
              onPress={() => act('rpc_deposit', { p_order: item.id }, '🔒 Money locked in escrow.')}
            >
              <Text style={styles.primaryBtnText}>Pay now</Text>
            </TouchableOpacity>
            <TouchableOpacity
              onPress={() => act('rpc_cancel_order', { p_order: item.id }, 'Order cancelled.')}
            >
              <Text style={styles.linkDanger}>Cancel</Text>
            </TouchableOpacity>
          </View>
        )}
      </View>
    );
  };

  return (
    <View style={styles.screen}>
      <View style={styles.header}>
        <TouchableOpacity onPress={() => router.back()}>
          <Text style={styles.back}>← Back</Text>
        </TouchableOpacity>
        <Text style={styles.h1}>My orders</Text>
      </View>
      <FlatList
        data={orders}
        keyExtractor={(o) => o.id}
        renderItem={renderItem}
        contentContainerStyle={{ padding: spacing.lg, paddingTop: 0 }}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
        ListEmptyComponent={
          loaded ? <Text style={styles.empty}>No orders yet.</Text> : null
        }
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.surface },
  header: { padding: spacing.lg, paddingTop: 60, paddingBottom: spacing.sm },
  back: { color: colors.gray, marginBottom: spacing.sm },
  h1: { fontSize: 26, fontWeight: '800', color: colors.black },
  card: {
    backgroundColor: colors.card, borderRadius: radius.lg,
    padding: spacing.md, marginBottom: spacing.sm,
    borderWidth: 1, borderColor: colors.grayLight,
  },
  cardTop: { flexDirection: 'row', gap: spacing.md },
  thumb: { width: 64, height: 64, borderRadius: radius.md },
  title: { fontSize: 15, fontWeight: '700', color: colors.black },
  total: { color: colors.black, fontWeight: '800', marginTop: 2 },
  roleTag: { color: colors.gray, fontSize: 12, marginTop: 2 },
  status: { fontWeight: '700', marginTop: spacing.sm },
  actionRow: {
    flexDirection: 'row', alignItems: 'center', gap: spacing.md,
    marginTop: spacing.sm, borderTopWidth: 1, borderTopColor: colors.grayLight,
    paddingTop: spacing.sm,
  },
  primaryBtn: {
    backgroundColor: colors.primary, borderRadius: radius.md,
    paddingHorizontal: spacing.lg, paddingVertical: spacing.sm,
  },
  primaryBtnText: { color: colors.white, fontWeight: '700' },
  dangerBtn: {
    borderWidth: 1, borderColor: colors.danger, borderRadius: radius.md,
    paddingHorizontal: spacing.lg, paddingVertical: spacing.sm,
  },
  dangerBtnText: { color: colors.danger, fontWeight: '700' },
  linkDanger: { color: colors.danger, fontWeight: '600' },
  empty: { color: colors.gray, textAlign: 'center', marginTop: 40 },
});
