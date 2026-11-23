// Conventional Commits: type(scope): subject, checked on pull requests by CI.
export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'subject-case': [0],
    'body-max-line-length': [0],
  },
}
