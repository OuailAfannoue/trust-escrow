// ============================================================================
// app/products.tsx — the seller's shop window.
// Lists their products with payment codes, ready to share into any DM.
// ============================================================================

import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import {
  FlatList,
  Image, RefreshControl, Share,
  StyleSheet,
  Text, TouchableOpacity,
  View,
} from 'react-native';
import { supabase } from '../lib/supabase';
import { colors, money, radius, spacing } from '../lib/theme';

type Link = { slug: string; status: string; use_count: number };
type Product = {
  id: string; title: string; price_mad: number;
  is_active: boolean; photos: string[]; payment_links: Link[];
};

export default function Products() {
  const router = useRouter();
  const [items, setItems] = useState<Product[]>([]);
  const [refreshing, setRefreshing] = useState(false);
  const [loaded, setLoaded] = useState(false);

  const fetchProducts = useCallback(async () => {
    const { data } = await supabase
      .from('products')
      .select('id, title, price_mad, is_active, photos, payment_links(slug, status, use_count)')
      .order('created_at', { ascending: false });
    setItems((data as Product[]) ?? []);
    setLoaded(true);
  }, []);

  // refetch every time the screen comes into focus (e.g. after publishing)
  useFocusEffect(useCallback(() => { fetchProducts(); }, [fetchProducts]));

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchProducts();
    setRefreshing(false);
  };

  const shareLink = (p: Product, slug: string) =>
    Share.share({
      message:
        `${p.title} — ${money(p.price_mad)}\n` +
        `Pay safely with TrustPay escrow: your money is protected until you inspect the delivery.\n` +
        `Open TrustPay and enter code: ${slug}`,
    });

  const renderItem = ({ item }: { item: Product }) => {
    const link = item.payment_links?.[0];
    return (
      <View style={styles.card}>
        <View style={styles.cardTop}>
          {item.photos?.[0] ? (
            <Image source={{ uri: item.photos[0] }} style={styles.thumb} />
          ) : (
            <View style={[styles.thumb, styles.thumbEmpty]} />
          )}
          <View style={{ flex: 1 }}>
            <Text style={styles.title} numberOfLines={2}>{item.title}</Text>
            <Text style={styles.price}>{money(item.price_mad)}</Text>
          </View>
        </View>
        {link && (
          <View style={styles.linkRow}>
            <View style={styles.slugPill}>
              <Text style={styles.slugText}>{link.slug}</Text>
            </View>
            <Text style={styles.uses}>{link.use_count} order{link.use_count === 1 ? '' : 's'}</Text>
            <TouchableOpacity style={styles.shareBtn} onPress={() => shareLink(item, link.slug)}>
              <Text style={styles.shareText}>Share ↗</Text>
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
        <Text style={styles.h1}>My products</Text>
        <TouchableOpacity style={styles.newBtn} onPress={() => router.push('/new-product')}>
          <Text style={styles.newBtnText}>＋ New product</Text>
        </TouchableOpacity>
      </View>

      <FlatList
        data={items}
        keyExtractor={(p) => p.id}
        renderItem={renderItem}
        contentContainerStyle={{ padding: spacing.lg, paddingTop: 0 }}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
        ListEmptyComponent={
          loaded ? (
            <Text style={styles.empty}>
              No products yet. Create your first listing — 90 seconds, phone
              camera, and you get a payment code to paste into any DM.
            </Text>
          ) : null
        }
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.surface },
  header: { padding: spacing.lg, paddingTop: 60 },
  back: { color: colors.gray, marginBottom: spacing.sm },
  h1: { fontSize: 26, fontWeight: '800', color: colors.black, marginBottom: spacing.sm },
  newBtn: {
    backgroundColor: colors.primary, borderRadius: radius.md,
    padding: spacing.md, alignItems: 'center',
  },
  newBtnText: { color: colors.white, fontWeight: '700', fontSize: 16 },
  card: {
    backgroundColor: colors.card, borderRadius: radius.lg,
    padding: spacing.md, marginBottom: spacing.sm,
    borderWidth: 1, borderColor: colors.grayLight,
  },
  cardTop: { flexDirection: 'row', gap: spacing.md },
  thumb: { width: 64, height: 64, borderRadius: radius.md },
  thumbEmpty: { backgroundColor: colors.grayLight },
  title: { fontSize: 16, fontWeight: '700', color: colors.black },
  price: { color: colors.primary, fontWeight: '800', marginTop: 2 },
  linkRow: {
    flexDirection: 'row', alignItems: 'center', gap: spacing.sm,
    marginTop: spacing.md, borderTopWidth: 1, borderTopColor: colors.grayLight,
    paddingTop: spacing.sm,
  },
  slugPill: {
    backgroundColor: colors.black, borderRadius: radius.pill,
    paddingHorizontal: spacing.md, paddingVertical: 4,
  },
  slugText: { color: colors.white, fontWeight: '700', letterSpacing: 1 },
  uses: { color: colors.gray, flex: 1 },
  shareBtn: {
    borderWidth: 1, borderColor: colors.primary, borderRadius: radius.pill,
    paddingHorizontal: spacing.md, paddingVertical: 4,
  },
  shareText: { color: colors.primary, fontWeight: '700' },
  empty: { color: colors.gray, textAlign: 'center', marginTop: 40, lineHeight: 20 },
});
