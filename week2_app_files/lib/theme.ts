// ============================================================================
// lib/theme.ts — one place for the whole visual identity.
// Change a color here, it changes everywhere.
// ============================================================================

export const colors = {
  primary: '#16A34A',      // trust green — actions, success, money-in
  primaryDark: '#15803D',
  black: '#0A0A0A',        // headlines, the wallet card
  white: '#FFFFFF',
  surface: '#F6F7F9',      // app background
  card: '#FFFFFF',
  gray: '#6B7280',         // secondary text
  grayLight: '#E5E7EB',    // borders
  danger: '#DC2626',       // errors, reject actions
};

export const spacing = { xs: 6, sm: 10, md: 16, lg: 24, xl: 32 };

export const radius = { md: 12, lg: 18, pill: 999 };

export const money = (n: unknown) =>
  `${Number(n ?? 0).toFixed(2)} MAD`;
