// Global settings for the self-hosted Renovate run in
// .github/workflows/renovate.yml. Settings for this repository are in
// .github/renovate.json5.
module.exports = {
  platform: 'github',
  onboarding: false,
  requireConfig: 'required',
  // The only command a postUpgradeTask may run: the script that bumps a
  // collection's version and adds its CHANGELOG.md entry.
  allowedCommands: ['^bash \\.github/renovate/bump-collection\\.sh$'],
};
