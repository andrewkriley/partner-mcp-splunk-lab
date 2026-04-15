import axios, { AxiosInstance, AxiosError } from 'axios';
import { parseString } from 'xml2js';
import { promisify } from 'util';
import https from 'https';
import * as querystring from 'querystring';

const parseXML = promisify(parseString);

export class SplunkAPIError extends Error {
  public statusCode?: number;
  public details: any;

  constructor(message: string, statusCode?: number, details: any = {}) {
    super(message);
    this.name = 'SplunkAPIError';
    this.statusCode = statusCode;
    this.details = details;
  }
}

interface SplunkConfig {
  splunk_host: string;
  splunk_port: number;
  splunk_username?: string;
  splunk_password?: string;
  splunk_token?: string;
  verify_ssl: boolean;
}

export class SplunkClient {
  private config: SplunkConfig;
  private baseURL: string;
  private client?: AxiosInstance;

  constructor(config: any) {
    this.config = {
      splunk_host: config.splunk_host,
      splunk_port: config.splunk_port || 8089,
      splunk_username: config.splunk_username,
      splunk_password: config.splunk_password,
      splunk_token: config.splunk_token,
      verify_ssl: config.verify_ssl || false,
    };
    this.baseURL = `https://${this.config.splunk_host}:${this.config.splunk_port}`;
  }

  async connect(): Promise<void> {
    const headers: any = {};
    let auth = undefined;

    if (this.config.splunk_token) {
      headers['Authorization'] = `Splunk ${this.config.splunk_token}`;
    } else if (this.config.splunk_username && this.config.splunk_password) {
      auth = {
        username: this.config.splunk_username,
        password: this.config.splunk_password,
      };
    } else {
      throw new SplunkAPIError(
        'No valid authentication configured. Set either SPLUNK_TOKEN or SPLUNK_USERNAME/SPLUNK_PASSWORD.'
      );
    }

    this.client = axios.create({
      baseURL: this.baseURL,
      auth,
      headers,
      timeout: parseInt(process.env.SPLUNK_TIMEOUT_MS || '120000', 10),
      httpsAgent: new https.Agent({
        rejectUnauthorized: this.config.verify_ssl,
      }),
    });
  }

  async disconnect(): Promise<void> {
    this.client = undefined;
  }

  private ensureConnected(): void {
    if (!this.client) {
      throw new SplunkAPIError('Client not connected. Call connect() first.');
    }
  }

  private async parseResponse(responseText: any, outputMode: string = 'json'): Promise<any[]> {
    if (outputMode === 'json') {
      // Ensure responseText is a string
      const textData = typeof responseText === 'string' ? responseText : JSON.stringify(responseText);
      
      try {
        // Try to parse as a single JSON object first (oneshot format)
        const data = JSON.parse(textData);
        if (data.results) {
          return data.results;
        } else if (data.result) {
          return [data.result];
        }
      } catch {
        // Fall back to line-by-line parsing (export format)
        const events: any[] = [];
        const lines = textData.trim().split('\n');
        for (const line of lines) {
          if (line.trim()) {
            try {
              const data = JSON.parse(line);
              if (data.result) {
                events.push(data.result);
              } else if (data.results) {
                events.push(...data.results);
              }
            } catch {
              continue;
            }
          }
        }
        return events;
      }
    } else {
      // Simple XML parsing for other formats
      const events: any[] = [];
      try {
        // Ensure responseText is a string for XML parsing too
        const textData = typeof responseText === 'string' ? responseText : JSON.stringify(responseText);
        const result: any = await parseXML(textData);
        // Navigate through the XML structure to find results
        // This is a simplified version - actual structure may vary
        if (result && result.results && result.results.result) {
          const results = Array.isArray(result.results.result) 
            ? result.results.result 
            : [result.results.result];
          
          for (const res of results) {
            const event: any = {};
            if (res.field) {
              const fields = Array.isArray(res.field) ? res.field : [res.field];
              for (const field of fields) {
                const key = field.$.k;
                const value = field.value?.[0]?.text?.[0] || '';
                event[key] = value;
              }
            }
            events.push(event);
          }
        }
      } catch {
        // XML parsing failed
      }
      return events;
    }
    // Default return empty array
    return [];
  }

  async searchOneshot(
    query: string,
    earliestTime: string = '-24h',
    latestTime: string = 'now',
    maxCount: number = 100
  ): Promise<any[]> {
    this.ensureConnected();

    // Don't prepend "search" if query starts with a pipe (|)
    const searchQuery = query.trim().startsWith('|') ? query : `search ${query}`;

    const params = {
      search: searchQuery,
      earliest_time: earliestTime,
      latest_time: latestTime,
      count: maxCount,
      output_mode: 'json',
    };

    try {
      const response = await this.client!.post('/services/search/jobs/oneshot', querystring.stringify(params), {
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded'
        }
      });
      // Handle the response based on its type
      if (typeof response.data === 'string') {
        return await this.parseResponse(response.data, 'json');
      } else if (response.data && response.data.results) {
        return response.data.results;
      } else if (response.data && response.data.result) {
        return [response.data.result];
      } else {
        return [];
      }
    } catch (error: any) {
      if (axios.isAxiosError(error)) {
        throw new SplunkAPIError(
          'Search failed',
          error.response?.status,
          { error: error.response?.data }
        );
      }
      // Include the full error stack for debugging
      throw new SplunkAPIError(`Search failed: ${error.message || error}`);
    }
  }

  async searchExport(
    query: string,
    earliestTime: string = '-24h',
    latestTime: string = 'now',
    maxCount: number = 100
  ): Promise<any[]> {
    this.ensureConnected();

    // Don't prepend "search" if query starts with a pipe (|)
    const searchQuery = query.trim().startsWith('|') ? query : `search ${query}`;

    const params = {
      search: searchQuery,
      earliest_time: earliestTime,
      latest_time: latestTime,
      count: maxCount,
      output_mode: 'json',
      search_mode: 'normal',
    };

    try {
      const response = await this.client!.post('/services/search/jobs/export', querystring.stringify(params), {
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded'
        }
      });
      
      // Handle the response based on its type
      let events: any[] = [];
      if (typeof response.data === 'string') {
        events = await this.parseResponse(response.data, 'json');
      } else if (response.data && response.data.results) {
        events = response.data.results;
      } else if (response.data && response.data.result) {
        events = [response.data.result];
      }
      
      // Limit results if needed
      if (maxCount > 0) {
        return events.slice(0, maxCount);
      }
      return events;
    } catch (error) {
      if (axios.isAxiosError(error)) {
        throw new SplunkAPIError(
          'Export search failed',
          error.response?.status,
          { error: error.response?.data }
        );
      }
      throw new SplunkAPIError(`Export search failed: ${error}`);
    }
  }

  async getIndexes(): Promise<any[]> {
    this.ensureConnected();

    try {
      const response = await this.client!.get('/services/data/indexes', {
        params: { output_mode: 'json' },
      });

      const data = response.data;
      const indexes: any[] = [];

      for (const entry of data.entry || []) {
        const content = entry.content || {};
        indexes.push({
          name: entry.name || '',
          datatype: content.datatype || 'event',
          totalEventCount: parseInt(content.totalEventCount || '0', 10),
          currentDBSizeMB: parseFloat(content.currentDBSizeMB || '0'),
          maxDataSize: content.maxDataSize || 'auto',
          maxTotalDataSizeMB: content.maxTotalDataSizeMB || 'unknown',
          minTime: content.minTime || '',
          maxTime: content.maxTime || '',
          disabled: content.disabled || false,
          frozenTimePeriodInSecs: content.frozenTimePeriodInSecs || '',
        });
      }

      return indexes;
    } catch (error) {
      if (axios.isAxiosError(error)) {
        throw new SplunkAPIError(
          'Failed to get indexes',
          error.response?.status,
          { error: error.response?.data }
        );
      }
      throw new SplunkAPIError(`Failed to get indexes: ${error}`);
    }
  }

  async getSavedSearches(): Promise<any[]> {
    this.ensureConnected();

    try {
      const response = await this.client!.get('/services/saved/searches', {
        params: { output_mode: 'json' },
      });

      const data = response.data;
      const savedSearches: any[] = [];

      for (const entry of data.entry || []) {
        const content = entry.content || {};
        savedSearches.push({
          name: entry.name || '',
          search: content.search || '',
          description: content.description || '',
          is_scheduled: content.is_scheduled || false,
          cron_schedule: content.cron_schedule || '',
          next_scheduled_time: content.next_scheduled_time || '',
          actions: content.actions || '',
        });
      }

      return savedSearches;
    } catch (error) {
      if (axios.isAxiosError(error)) {
        throw new SplunkAPIError(
          'Failed to get saved searches',
          error.response?.status,
          { error: error.response?.data }
        );
      }
      throw new SplunkAPIError(`Failed to get saved searches: ${error}`);
    }
  }

  async runSavedSearch(searchName: string, triggerActions: boolean = false): Promise<any> {
    this.ensureConnected();

    try {
      // Dispatch the saved search
      const dispatchUrl = `/services/saved/searches/${searchName}/dispatch`;
      const params = {
        trigger_actions: triggerActions ? '1' : '0',
        output_mode: 'json',
      };

      const response = await this.client!.post(dispatchUrl, querystring.stringify(params), {
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded'
        }
      });

      // Get job ID
      const jobData = response.data;
      const jobId = jobData.sid;

      if (!jobId) {
        throw new SplunkAPIError('No job ID returned from saved search dispatch');
      }

      // Poll for completion
      const jobUrl = `/services/search/jobs/${jobId}`;
      while (true) {
        const jobResponse = await this.client!.get(jobUrl, {
          params: { output_mode: 'json' },
        });

        const jobInfo = jobResponse.data;
        const entry = jobInfo.entry?.[0] || {};
        const content = entry.content || {};

        if (content.dispatchState === 'DONE') {
          break;
        }

        await new Promise(resolve => setTimeout(resolve, 500));
      }

      // Get results
      const resultsUrl = `/services/search/jobs/${jobId}/results`;
      const resultsResponse = await this.client!.get(resultsUrl, {
        params: { output_mode: 'json', count: 100 },
      });

      const events = await this.parseResponse(resultsResponse.data, 'json');

      return {
        search_name: searchName,
        job_id: jobId,
        event_count: events.length,
        events,
      };
    } catch (error) {
      if (axios.isAxiosError(error)) {
        throw new SplunkAPIError(
          'Failed to run saved search',
          error.response?.status,
          { error: error.response?.data }
        );
      }
      throw new SplunkAPIError(`Failed to run saved search: ${error}`);
    }
  }

  // Async context manager support
  async [Symbol.asyncDispose](): Promise<void> {
    await this.disconnect();
  }
}