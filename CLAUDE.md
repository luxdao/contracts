# CLAUDE.md

Documentation lives in [README.md](./README.md) @./README.md

## Quick Reference

### Key Conventions

- **Parameter naming**: All function parameters use trailing underscore (e.g., `amount_`)
- **Version suffixes**: Concrete contracts include V1 suffix, abstract contracts do not
- **Security contact**: All main contracts include `@custom:security-contact security@decentlabs.io`
- **Documentation principle**: Use `@inheritdoc` for interface functions - never duplicate docs
- **Deployment patterns**: See README.md for deployment categories (Deployables, Singletons, Utilities, Services)

## NatSpec Documentation Guidelines

### Core Principles

1. **Interface First**: Comprehensive documentation belongs in interfaces
2. **Use @inheritdoc**: Avoid duplicating documentation between interfaces and implementations
3. **Clarity**: Help developers understand contract usage without reading implementation
4. **Consistency**: Follow established patterns for all documentation

### Contract Documentation Patterns

#### Interfaces

```solidity
 /**
 * @title IContractName
 * @notice High-level one-line description of the interface's purpose
 * @dev Comprehensive explanation of the contract's role in the system.
 *
 * Key features:
 * - Feature 1 with brief explanation
 * - Feature 2 with brief explanation
 *
 * Integration requirements:
 * - Requirement 1 (e.g., "Must be registered as Safe module")
 * - Requirement 2 (e.g., "Requires specific roles for operation")
 *
 * [Additional sections as needed like "Voting mechanics:", "Security model:", etc.]
 */
```

#### Implementation Contracts

```solidity
 /**
 * @title ContractNameV1  // Note: Concrete contracts include V1 suffix
 * @author Decent Labs
 * @notice Implementation of IContractName providing [brief functional description]
 * @dev This contract implements IContractName, providing [what it does].
 *
 * Implementation details:
 * - Uses EIP-7201 namespaced storage pattern
 * - UUPS upgradeable with owner-restricted upgrades
 * - Integrates with [external contracts/protocols]
 * - [Other technical implementation details]
 *
 * @custom:security-contact security@decentlabs.io
 */
```

#### Abstract Contracts

```solidity
 /**
 * @title BaseContract  // Note: No V1 suffix for abstract contracts
 * @author Decent Labs
 * @notice Abstract base contract for [what it provides]
 * @dev Provides core functionality that concrete implementations extend.
 *
 * Implementation details:
 * - [List key functionality provided]
 * - Must be extended by concrete contracts
 *
 * @custom:security-contact security@decentlabs.io
 */
```

#### Standalone Contracts (No Interface)

Include full documentation following the interface pattern since there's no separate interface.

### Function Documentation

#### Interface Functions in Implementations

```solidity
/**
 * @inheritdoc IContractName
 */
function someFunction() external;

// With implementation details:
/**
 * @inheritdoc IContractName
 * @dev Implementation uses [specific approach] to achieve [goal].
 * Validates [what] before [action].
 */
```

#### New Functions (Not in Interface)

```solidity
 /**
 * @notice [Brief description of what the function does]
 * @dev [Technical details, implementation notes, security considerations]
 * @param paramName_ [Description of parameter and constraints]
 * @return returnName [Description of return value]
 * @custom:throws ErrorName if [condition]
 */
```

### State Variables and Storage

#### EIP-7201 Storage Pattern

```solidity
/**
 * @notice Main storage struct for ContractName following EIP-7201
 * @dev Contains all [category] state including [what it stores]
 * @custom:storage-location erc7201:Decent.ContractName.main
 */
struct ContractStorage {
  /** @notice [What this variable tracks/represents] */
  uint256 variable1;
  /** @notice [Purpose of this mapping] */
  mapping(address => uint256) variable2;
}
```

#### Storage Getter Functions

```solidity
/**
 * @dev Returns the storage struct for ContractName
 * Following the EIP-7201 namespaced storage pattern to avoid storage collisions
 * @return $ The storage struct for ContractName
 */
function _getContractStorage() internal pure returns (ContractStorage storage $) {
  // implementation
}
```

### Other Documentation Elements

#### Events

```solidity
/**
 * @notice Emitted when [action that triggers the event]
 * @param account [Description of what this parameter represents]
 * @param amount [Description including any constraints or special values]
 */
event EventName(address indexed account, uint256 amount);
```

#### Errors

```solidity
/** @notice Thrown when [specific condition that causes the error] */
error SimpleError();

/** @notice Thrown when [condition] with [parameter context] */
error ErrorWithContext(address account, uint256 expected, uint256 actual);
```

#### Enums

```solidity
/**
 * @notice [What this enum represents]
 * @dev [How the enum is used in the contract]
 *
 * Values:
 * - VALUE1: [What this value means and when it's used]
 * - VALUE2: [What this value means and when it's used]
 */
enum Status {
  VALUE1,
  VALUE2
}
```

For state machine enums, include transition information in the @dev section.

#### Modifiers

```solidity
/**
 * @notice [What this modifier ensures/checks]
 * @dev [When this modifier should be used]
 * @custom:throws ErrorName if [condition]
 */
modifier onlyAuthorized() {
    // implementation
}
```

#### Constants

```solidity
/** @notice [What this constant represents and how it's used] */
bytes32 public constant CONSTANT_NAME = keccak256("CONSTANT_NAME");
```

### Inline Documentation

For complex functions (>30 lines) or intricate logic, add inline comments:

```solidity
function complexFunction(uint256 param_) external {
  // Step 1: Validate inputs and check preconditions
  require(param_ > 0, 'Invalid param');

  // Calculate weighted average using formula:
  // weightedAvg = (value1 * weight1 + value2 * weight2) / totalWeight
  uint256 weightedAvg = _calculateWeightedAverage();

  // External call last to prevent reentrancy
  externalContract.notify(param_);
}
```

### Section Headers

#### Interface Section Headers

Use simple single-line delimiters:

```solidity
 // --- Section Name ---
```

Order: Errors → Structs → Enums → Events → Initializers → Pure → View → State-Changing Functions

#### Contract Section Headers

Use 70-character wide headers:

```solidity
 // ======================================================================
// SECTION NAME
// ======================================================================
```

Order: STATE VARIABLES → MODIFIERS → CONSTRUCTOR & INITIALIZERS → [Interface Names] → INTERNAL HELPERS

Within interface sections, use the same subsection format as interfaces (e.g., `// --- View Functions ---`).

### Common Pitfalls to Avoid

1. **Never duplicate interface documentation** - Always use @inheritdoc
2. **Don't use @dev inside enum declarations** - Put it in the header comment
3. **Include @return $** for storage getter functions
4. **Don't document upgradeability in interfaces** - It's an implementation detail
5. **Don't forget IERC165** when documenting supportsInterface
6. **Run tests before documenting** to ensure accuracy
7. **Don't add comments unless asked** - Let NatSpec handle documentation

### Documentation Workflow

1. **Read interface first** (if exists) to understand the contract's API
2. **Use @inheritdoc** for all interface functions
3. **Document only implementation-specific details** in concrete contracts
4. **Add inline comments** only for complex logic (>30 lines)
5. **Cross-reference with tests** to ensure accuracy

## Git Commit Messages and Linear Tickets

When asked to create git commit messages or Linear tickets, follow these guidelines:

### Git Commit Messages & GitHub PRs

This project follows a one-commit-per-PR workflow. The first line of the commit message becomes the PR title, and the rest becomes the PR description.

**Format:**

- **Subject Line**: Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) specification
  - Format: `<type>(<scope>): <subject>`
  - Example: `feat(contracts): Implement new proxy factory`
- **Message Body**:
  - **Motivation**: High-level description of _what_ changed and _why_
  - **Change Summary**: Comprehensive, bulleted list of key changes

### Linear Tickets

**Format:**

- **Title**: Concise summary of the work
- **Description**: Always in **future tense** (as if work is about to start)
  - Clear goals and specific tasks as checklist items

### Output Location

When generating commit messages and Linear tickets:

1. Create files in `./tmp/commit-and-ticket-messages/`
2. Use descriptive filenames like `<feature-name>-<action>.md`
3. Include both git commit message and Linear ticket in the same file
4. Wrap each section in markdown code blocks for easy copying
5. When creating lists, use the `-` character

Example: `./tmp/commit-and-ticket-messages/autonomous-admin-systemdeployer-refactor.md`

## Project Plans

When creating project plans, implementation plans, or technical design documents:

### Output Location

1. Create files in `./tmp/project-plans/`
2. Use descriptive filenames like `<feature-name>-implementation-plan.md`
3. Include clear sections for overview, steps, and notes

### What to Include

- **Overview**: Brief description of what the plan accomplishes
- **Implementation Steps**: Numbered list of specific actions
- **Benefits**: Key advantages of the approach
- **Notes**: Important considerations or caveats

Example: `./tmp/project-plans/solhint-implementation-plan.md`

## Code Quality Requirements

### Code Formatting (TypeScript and Solidity)

The project uses Prettier to format both TypeScript and Solidity code. When modifying any code, you MUST run prettier to ensure code passes GitHub CI checks:

```shell
npm run pretty              # Format all files
npm run pretty:check        # Check formatting without fixing
```

This single command formats both TypeScript (`.ts`) and Solidity (`.sol`) files.

**Critical**: GitHub CI will fail if code doesn't match prettier formatting rules.

**Solidity configuration**:

- 80 character line width
- 4 spaces indentation
- Double quotes for strings

### TypeScript Linting

The project uses ESLint for TypeScript code analysis:

```shell
npm run lint                # Lint and fix issues
npm run lint:check          # Check issues without fixing
```

### Solidity Linting

The project uses Solhint for Solidity code analysis and security patterns:

```shell
npm run solhint             # Check and fix issues
npm run solhint:check       # Check issues without fixing
```

Enforces best practices and project-specific rules defined in `.solhint.json`.

### When to Run Code Quality Checks

Always run these commands before committing:

1. `npm run pretty` - Format all code
2. `npm run lint` - Lint TypeScript files
3. `npm run solhint` - Lint Solidity contracts

This ensures your code passes all automated CI checks.
