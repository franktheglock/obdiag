/**
 * Test environment defaults.
 *
 * Some modules import the Firebase Admin SDK transitively. Setting a project id
 * keeps `initializeApp()` from reaching for the GCE metadata server during unit
 * tests; no Firestore connection is made by the pure tests.
 */

process.env.GCLOUD_PROJECT ??= "obdiag-test";
process.env.GOOGLE_CLOUD_PROJECT ??= "obdiag-test";
