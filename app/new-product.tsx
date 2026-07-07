// ============================================================================
// app/new-product.tsx — the mandatory detailed listing.
// The database will refuse anything with < 2 photos or a thin description;
// this screen enforces the same rules kindly, before the user hits submit.
// On success: photos → storage, product → DB, payment link generated & shared.
// ============================================================================

import { decode } from 'base64-arraybuffer';
import * as ImagePicker from 'expo-image-picker';
import { useRouter } from 'expo-router';
import { useState } from 'react';
import {
  ActivityIndicator, Alert,
  Image,
  ScrollView,
  Share,
  StyleSheet,
  Text, TextInput, TouchableOpacity,
  View,
} from 'react-native';
import { supabase } from '../lib/supabase';
import { colors, radius, spacing } from '../lib/theme';

const CATEGORIES = ['electronics', 'fashion', 'beauty', 'home', 'other'];
const CONDITIONS = [
  { key: 'new', label: 'New' },
  { key: 'like_new', label: 'Like new' },
  { key: 'used', label: 'Used' },
] as const;

type Photo = { uri: string; base64: string };

export default function NewProduct() {
  const router = useRouter();
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [category, setCategory] = useState('electronics');
  const [condition, setCondition] = useState<'new' | 'like_new' | 'used'>('new');
  const [price, setPrice] = useState('');
  const [photos, setPhotos] = useState<Photo[]>([]);
  const [busy, setBusy] = useState(false);

  const pickPhotos = async () => {
    const result = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ['images'],
      allowsMultipleSelection: true,
      selectionLimit: 6,
      quality: 0.7,
      base64: true,
    });
    if (result.canceled) return;
    const picked = result.assets
      .filter((a) => a.base64)
      .map((a) => ({ uri: a.uri, base64: a.base64 as string }));
    setPhotos((prev) => [...prev, ...picked].slice(0, 6));
  };

  const removePhoto = (uri: string) =>
    setPhotos((prev) => prev.filter((p) => p.uri !== uri));

  const submit = async () => {
    // mirror the database's own rules, with friendlier words
    if (title.trim().length < 5) return Alert.alert('Almost', 'Title needs at least 5 characters.');
    if (description.trim().length < 20)
      return Alert.alert('Almost', 'Description needs at least 20 characters — detail is your protection in disputes.');
    const priceNum = parseFloat(price.replace(',', '.'));
    if (!priceNum || priceNum <= 0) return Alert.alert('Almost', 'Enter a valid price in MAD.');
    if (photos.length < 2)
      return Alert.alert('Almost', 'At least 2 photos are required — they are the evidence buyers trust.');

    setBusy(true);
    try {
      // whoami (needed for the storage folder + seller_id)
      const { data: prof, error: pe } = await supabase
        .from('profiles').select('id').single();
      if (pe || !prof) throw new Error(pe?.message ?? 'Profile not found');

      // 1) upload photos into MY folder
      const urls: string[] = [];
      for (let i = 0; i < photos.length; i++) {
        const path = `${prof.id}/${Date.now()}-${i}.jpg`;
        const { error: ue } = await supabase.storage
          .from('product-photos')
          .upload(path, decode(photos[i].base64), { contentType: 'image/jpeg' });
        if (ue) throw new Error(`Photo ${i + 1}: ${ue.message}`);
        urls.push(supabase.storage.from('product-photos').getPublicUrl(path).data.publicUrl);
      }

      // 2) create the product (RLS checks I'm a seller and it's mine)
      const { data: product, error: ie } = await supabase
        .from('products')
        .insert({
          seller_id: prof.id,
          title: title.trim(),
          description: description.trim(),
          category,
          condition,
          price_mad: priceNum,
          photos: urls,
        })
        .select('id')
        .single();
      if (ie || !product) throw new Error(ie?.message ?? 'Insert failed');

      // 3) generate the shareable payment link
      const { data: slug, error: le } = await supabase
        .rpc('rpc_create_payment_link', { p_product: product.id });
      if (le) throw new Error(le.message);

      setBusy(false);
      Alert.alert('Product live! 🎉', `Payment code: ${slug}`, [
        {
          text: 'Share it',
          onPress: () =>
            Share.share({
              message:
                `${title.trim()} — ${priceNum} MAD\n` +
                `Pay safely with TrustPay escrow: your money is protected until you inspect the delivery.\n` +
                `Open TrustPay and enter code: ${slug}`,
            }).finally(() => router.replace('/products')),
        },
        { text: 'Done', onPress: () => router.replace('/products') },
      ]);
    } catch (e: any) {
      setBusy(false);
      Alert.alert('Could not publish', e.message);
    }
  };

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <TouchableOpacity onPress={() => router.back()}>
        <Text style={styles.back}>← Back</Text>
      </TouchableOpacity>
      <Text style={styles.h1}>New product</Text>
      <Text style={styles.sub}>
        Detailed listings sell more and win disputes. Photos + description are
        frozen into every order as evidence.
      </Text>

      {/* photos */}
      <View style={styles.photoRow}>
        {photos.map((p) => (
          <TouchableOpacity key={p.uri} onLongPress={() => removePhoto(p.uri)}>
            <Image source={{ uri: p.uri }} style={styles.thumb} />
          </TouchableOpacity>
        ))}
        {photos.length < 6 && (
          <TouchableOpacity style={styles.addPhoto} onPress={pickPhotos}>
            <Text style={styles.addPhotoText}>＋</Text>
            <Text style={styles.addPhotoHint}>{photos.length}/2 min</Text>
          </TouchableOpacity>
        )}
      </View>
      <Text style={styles.hint}>Long-press a photo to remove it.</Text>

      <TextInput
        style={styles.input} placeholder="Title (e.g. iPhone 12 128GB Black)"
        placeholderTextColor={colors.gray} value={title} onChangeText={setTitle}
      />
      <TextInput
        style={[styles.input, styles.multiline]} multiline numberOfLines={4}
        placeholder="Description — model, storage, condition details, what's included..."
        placeholderTextColor={colors.gray} value={description} onChangeText={setDescription}
      />
      <TextInput
        style={styles.input} placeholder="Price in MAD" keyboardType="decimal-pad"
        placeholderTextColor={colors.gray} value={price} onChangeText={setPrice}
      />

      <Text style={styles.label}>Category</Text>
      <View style={styles.chipRow}>
        {CATEGORIES.map((c) => (
          <TouchableOpacity
            key={c}
            style={[styles.chip, category === c && styles.chipActive]}
            onPress={() => setCategory(c)}
          >
            <Text style={[styles.chipText, category === c && styles.chipTextActive]}>{c}</Text>
          </TouchableOpacity>
        ))}
      </View>

      <Text style={styles.label}>Condition</Text>
      <View style={styles.chipRow}>
        {CONDITIONS.map((c) => (
          <TouchableOpacity
            key={c.key}
            style={[styles.chip, condition === c.key && styles.chipActive]}
            onPress={() => setCondition(c.key)}
          >
            <Text style={[styles.chipText, condition === c.key && styles.chipTextActive]}>
              {c.label}
            </Text>
          </TouchableOpacity>
        ))}
      </View>

      <TouchableOpacity style={styles.cta} onPress={submit} disabled={busy}>
        {busy ? <ActivityIndicator color={colors.white} />
              : <Text style={styles.ctaText}>Publish & get payment link</Text>}
      </TouchableOpacity>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.surface },
  content: { padding: spacing.lg, paddingTop: 60, paddingBottom: 60 },
  back: { color: colors.gray, marginBottom: spacing.sm },
  h1: { fontSize: 26, fontWeight: '800', color: colors.black },
  sub: { color: colors.gray, marginTop: 4, marginBottom: spacing.md, lineHeight: 19 },
  photoRow: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  thumb: { width: 76, height: 76, borderRadius: radius.md },
  addPhoto: {
    width: 76, height: 76, borderRadius: radius.md, borderWidth: 1.5,
    borderStyle: 'dashed', borderColor: colors.gray,
    alignItems: 'center', justifyContent: 'center',
  },
  addPhotoText: { fontSize: 24, color: colors.gray },
  addPhotoHint: { fontSize: 10, color: colors.gray },
  hint: { color: colors.gray, fontSize: 12, marginTop: 6, marginBottom: spacing.md },
  input: {
    backgroundColor: colors.card, borderWidth: 1, borderColor: colors.grayLight,
    borderRadius: radius.md, padding: spacing.md, fontSize: 16,
    marginBottom: spacing.sm, color: colors.black,
  },
  multiline: { minHeight: 96, textAlignVertical: 'top' },
  label: { color: colors.black, fontWeight: '700', marginTop: spacing.sm, marginBottom: 6 },
  chipRow: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.xs },
  chip: {
    paddingHorizontal: spacing.md, paddingVertical: spacing.xs,
    borderRadius: radius.pill, borderWidth: 1, borderColor: colors.grayLight,
    backgroundColor: colors.card,
  },
  chipActive: { backgroundColor: colors.black, borderColor: colors.black },
  chipText: { color: colors.gray },
  chipTextActive: { color: colors.white },
  cta: {
    backgroundColor: colors.primary, borderRadius: radius.md,
    padding: spacing.md, alignItems: 'center', marginTop: spacing.lg,
  },
  ctaText: { color: colors.white, fontSize: 17, fontWeight: '700' },
});
