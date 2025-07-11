# Rinha 2025 - Crystal Version

A high-performance payment processing system built with Crystal, featuring circuit breaker pattern for resilient external API calls.

## Architecture

- **HTTP Server**: Handles payment creation and summary endpoints using Kemal
- **Consumer**: Watches MongoDB changes and processes payments with circuit breaker
- **Circuit Breaker**: Latency-based fallback mechanism using TPei/circuit_breaker shard
- **MongoDB Integration**: Stores requested and processed payments using Cryomongo

## Dependencies

- **Kemal**: HTTP server framework
- **Cryomongo**: MongoDB driver for Crystal
- **Circuit Breaker**: Resilient external API calls

## Installation

1. Install Crystal (version 1.0.0 or higher)
2. Install dependencies:
   ```bash
   make deps
   ```

## Configuration

Set the following environment variables:

```bash
# Server configuration
PORT=3000                    # HTTP server port (default: 3000)
USE_PROXY=true              # Optional: proxy requests to another server

# MongoDB configuration
MONGO_URI=mongodb://localhost:27017  # MongoDB connection string

# Consumer configuration
PROCESSOR_URL=http://localhost:8080  # Primary payment processor URL
FALLBACK_URL=http://localhost:8081   # Fallback payment processor URL
TOKEN=your-auth-token               # Authentication token for processors
```

## Usage

### Build the applications:
```bash
make build
```

### Run the HTTP server:
```bash
make run-server
```

### Run the consumer (in another terminal):
```bash
make run-consumer
```

### Development mode:
```bash
# Terminal 1: Run server in development mode
make dev-server

# Terminal 2: Run consumer in development mode
make dev-consumer
```

## API Endpoints

### POST /payments
Create a new payment request.

**Request body:**
```json
{
  "amount": 100.50,
  "description": "Payment description"
}
```

**Response:**
```json
{
  "amount": 100.50,
  "description": "Payment description",
  "timestamp": "2025-01-01T12:00:00Z"
}
```

### GET /payment-summary
Get payment summary (currently returns empty object).

## Circuit Breaker

The circuit breaker monitors the p75 latency of the primary processor:
- **Threshold**: 100ms (configurable)
- **Behavior**: Switches to fallback when p75 > threshold
- **Recovery**: Automatic based on improved latency

## MongoDB Collections

- **requested_payments**: Stores incoming payment requests
- **processed_payments**: Stores payments sent to external processors

## Development

The consumer uses a polling approach to watch for new payments. In a production environment, you might want to implement proper MongoDB change streams if supported by the driver.

## Building for Production

```bash
make build
```

This creates optimized binaries in the `bin/` directory.

## Migration from JavaScript

This Crystal version maintains the same API and behavior as the original JavaScript implementation while providing:
- Better performance
- Type safety
- Lower memory usage
- Concurrent processing capabilities 