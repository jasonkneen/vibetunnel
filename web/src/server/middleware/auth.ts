import { Request, Response, NextFunction } from 'express';
import chalk from 'chalk';

interface AuthConfig {
  basicAuthUsername: string | null;
  basicAuthPassword: string | null;
  isHQMode: boolean;
  bearerToken?: string; // Token that HQ must use to authenticate with this remote
}

export function createAuthMiddleware(config: AuthConfig) {
  return (req: Request, res: Response, next: NextFunction) => {
    // Skip auth for health check endpoint
    if (req.path === '/api/health') {
      return next();
    }

    // If no auth configured, allow all requests
    if (!config.basicAuthUsername || !config.basicAuthPassword) {
      return next();
    }

    console.log(
      `Auth check: ${req.method} ${req.path}, auth header: ${req.headers.authorization || 'none'}`
    );

    // Check for Bearer token (for HQ to remote communication)
    const authHeader = req.headers.authorization;
    if (authHeader && authHeader.startsWith('Bearer ')) {
      const token = authHeader.substring(7);
      // In HQ mode, bearer tokens are not accepted (HQ uses basic auth)
      if (config.isHQMode) {
        res.setHeader('WWW-Authenticate', 'Basic realm="VibeTunnel"');
        return res.status(401).json({ error: 'Bearer token not accepted in HQ mode' });
      } else if (config.bearerToken && token === config.bearerToken) {
        // Token matches what this remote server expects from HQ
        return next();
      } else if (config.bearerToken) {
        // We have a bearer token configured but it doesn't match
        console.log(`Bearer token mismatch: expected ${config.bearerToken}, got ${token}`);
      }
    } else {
      console.log(`No bearer token in request, bearerToken configured: ${!!config.bearerToken}`);
    }

    // Check Basic auth
    if (authHeader && authHeader.startsWith('Basic ')) {
      const base64Credentials = authHeader.substring(6);
      const credentials = Buffer.from(base64Credentials, 'base64').toString('utf8');
      const [username, password] = credentials.split(':');

      if (username === config.basicAuthUsername && password === config.basicAuthPassword) {
        return next();
      }
    }

    // No valid auth provided
    console.log(chalk.red(`Unauthorized request to ${req.method} ${req.path} from ${req.ip}`));
    res.setHeader('WWW-Authenticate', 'Basic realm="VibeTunnel"');
    res.status(401).json({ error: 'Authentication required' });
  };
}
