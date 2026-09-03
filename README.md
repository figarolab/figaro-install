# Figaro Secure Gateway — installer

Questo repository contiene **un solo file**, `bootstrap.sh`: l'innesco che installa
Figaro Secure Gateway su una macchina nuova.

Non contiene il prodotto e non contiene credenziali. Scarica la configurazione
ufficiale e le immagini Docker dai repository privati del fornitore, raggiungibili
**solo** con il token di accesso che ti viene consegnato insieme al contratto.

## Installazione

```bash
curl -fsSLO https://raw.githubusercontent.com/figarolab/figaro-install/main/bootstrap.sh
sha256sum bootstrap.sh          # confronta con l'impronta ricevuta via email
bash bootstrap.sh
```

Senza argomenti installa l'ultima versione disponibile. Per fissarne una precisa:
`bash bootstrap.sh v0.1.121`.

Il secondo comando verifica che il file scaricato sia esattamente quello pubblicato
dal fornitore: l'impronta SHA-256 arriva per email, insieme al token. Se i due valori
non coincidono, **non eseguire lo script** e contatta il fornitore.

Non usare `curl … | bash`: scarica, verifica, esegui.

## Prerequisiti sulla macchina

- Docker con il plugin Compose v2 (`docker compose version`)
- `git`, `curl`, `openssl`
- porte 80 e 443 libere (o indica porte diverse quando l'installer le chiede)

## Cosa succede quando lo esegui

1. Ti chiede il token di accesso (non viene mostrato a schermo).
2. Scarica la configurazione ufficiale della versione richiesta.
3. Avvia l'installer interattivo, che chiede: nome host pubblico, email
   dell'amministratore, nome dell'organizzazione, tipo di certificato HTTPS, porte
   e backend di inferenza.
4. Scarica le immagini, genera segreti e certificati, avvia i servizi e attende che
   siano tutti sani.
5. Stampa indirizzi e credenziali del primo accesso.

Niente viene installato finché non hai risposto alle domande.

## Se qualcosa va storto

L'installer si ferma indicando il passo fallito e lo stato dei servizi. Si riparte
dalla cartella creata dal bootstrap:

```bash
cd figaro-secure-gateway
bash install.sh --reinstall     # ATTENZIONE: azzera anche i dati già presenti
```

Per il resto, l'assistenza è quella prevista dal contratto.
